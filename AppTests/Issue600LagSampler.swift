import Foundation
import Darwin

struct Sample600Stamp: Sendable {
    let name: String
    let instant: ContinuousClock.Instant
    var pid: Int32? = nil
    var signalResult: Int32? = nil
    var signalErrno: Int32? = nil
    func line(relativeTo origin: ContinuousClock.Instant) -> String {
        "shared=+\(origin.duration(to: instant)) event=\(name)" +
            (pid.map { " pid=\($0)" } ?? "") +
            (signalResult.map { " signalReturn=\($0)" } ?? "") +
            (signalErrno.map { " errno=\($0)" } ?? "")
    }
}

struct Sample600Capture: Sendable {
    let status: String
    let raw: String
    let childPID: Int32?
    let joined: Bool
    let progress: String
    let lifecycle: [Sample600Stamp]
    init(_ status: String, raw: String = "", childPID: Int32? = nil, joined: Bool = true, progress: String = "", lifecycle: [Sample600Stamp] = []) {
        self.status = status; self.raw = raw; self.childPID = childPID; self.joined = joined
        self.progress = progress; self.lifecycle = lifecycle
    }
}

struct Sample600Report: Sendable {
    let status: String
    let text: String
}

struct Sample600Result: Sendable {
    let status: String
    let text: String
    let triggerJob: UUID?
    let childPID: Int32?
    let targetPID: Int32
    let joined: Bool
    let rawRemoved: Bool
    let attempts: Int
    let queuedToEntryMilliseconds: Double?
    var lifecycle: [Sample600Stamp] = []
}

struct Sample600State: Sendable {
    let pending: [UUID: ContinuousClock.Instant]
    let spent: Bool
    let running: Bool
    let attempts: Int
}

/// Test-only own-process diagnostic. No process is launched from the observer or MainActor.
final class ScanLag600Sampler: @unchecked Sendable {
    static let maximumBytes = 16_000
    static let maximumLines = 120
    typealias Capture = @Sendable (URL) -> Sample600Capture
    private struct Pending {
        let queued: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        let work: DispatchWorkItem?
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "i600.stack-sample", qos: .userInitiated, attributes: .concurrent)
    private static let watchdog = DispatchQueue(label: "i600.stack-sample.watchdog", qos: .userInitiated)
    private let enabled: Bool
    private let milliseconds: Int
    private let manual: Bool
    private let capture: Capture
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lifecycle: [Sample600Stamp] = []
    private var trigger: (UUID, ContinuousClock.Instant)?
    private var triggerEntry: ContinuousClock.Instant?
    private let completion: @Sendable () -> Void
    private var pending: [UUID: Pending] = [:]
    private var spent = false
    private var running = false
    private var closed = false
    private var attempts = 0
    private var result: Sample600Result?
    private var maximumLateEntry: Duration?
    private var waiters: [CheckedContinuation<Sample600Result, Never>] = []

    init(enabled: Bool = true, milliseconds: Int = 750, manualTrigger: Bool = false,
         capture: Capture? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, onCompletion: @escaping @Sendable () -> Void = {}) {
        self.enabled = enabled; self.milliseconds = milliseconds; manual = manualTrigger
        self.capture = capture ?? { Self.runSample($0) }
        self.now = now
        completion = onCompletion
    }
    func observe(_ event: FolderOpenStageEvent) {
        guard event.kind == .job, event.stage == "scan.task", let id = event.jobID else { return }
        if event.outcome != .queued {
            lock.withLock {
                if running, trigger?.0 == id, triggerEntry == nil, event.outcome == .entered,
                   let queued = trigger?.1 {
                    triggerEntry = event.instant
                    maximumLateEntry = queued.duration(to: event.instant)
                    lifecycle.append(.init(name: "trigger.entered", instant: event.instant))
                }
                guard let previous = pending.removeValue(forKey: id) else { return }
                previous.work?.cancel()
                if event.outcome == .entered, event.instant > previous.deadline {
                    let lag = previous.deadline.duration(to: event.instant) + .milliseconds(milliseconds)
                    if maximumLateEntry == nil || lag > maximumLateEntry! { maximumLateEntry = lag }
                }
            }
            return
        }
        lock.withLock {
            guard enabled, !closed, !spent, pending[id] == nil else { return }
            let work: DispatchWorkItem? = manual ? nil : DispatchWorkItem { [weak self] in _ = self?.reserve(id) }
            pending[id] = Pending(queued: event.instant, deadline: event.instant.advanced(by: .milliseconds(milliseconds)), work: work)
            if let work { worker.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work) }
        }
    }
    func cancel(_ job: UUID) {
        lock.withLock { pending.removeValue(forKey: job)?.work?.cancel() }
    }
    /// Reservation is the atomic winner: entry before it suppresses launch; entry
    /// after it cannot abandon the already-owned child. Case quota is consumed here.
    @discardableResult private func reserve(_ job: UUID) -> Bool {
        let admitted = lock.withLock {
            guard enabled, !closed, !spent, let selected = pending[job] else { return false }
            lifecycle.append(.init(name: "timer.executed", instant: now()))
            lifecycle.append(.init(name: "trigger.queued", instant: selected.queued))
            lifecycle.append(.init(name: "timer.deadline", instant: selected.deadline))
            lifecycle.append(.init(name: "reservation", instant: now()))
            trigger = (job, selected.queued)
            spent = true; running = true; attempts += 1
            for entry in pending.values { entry.work?.cancel() }
            pending.removeAll()
            return true
        }
        if admitted { worker.async { self.collect(job) } }
        return admitted
    }
    @discardableResult func fireForTest(_ job: UUID) -> Bool { reserve(job) }
    func state() -> Sample600State {
        lock.withLock { .init(pending: pending.mapValues(\.deadline), spent: spent, running: running, attempts: attempts) }
    }
    func finish() async -> Sample600Result {
        await withCheckedContinuation { waiter in
            let ready: Sample600Result? = lock.withLock {
                closed = true
                for entry in pending.values { entry.work?.cancel() }
                pending.removeAll()
                if running { waiters.append(waiter); return nil }
                return result ?? .init(status: maximumLateEntry == nil ? "not-triggered" : "lag-observed-trigger-missed",
                    text: "", triggerJob: nil, childPID: nil, targetPID: getpid(), joined: true,
                    rawRemoved: true, attempts: attempts, queuedToEntryMilliseconds: Self.milliseconds(maximumLateEntry))
            }
            if let ready { waiter.resume(returning: ready) }
        }
    }
    private func collect(_ job: UUID) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("i600-profile-\(UUID())", isDirectory: true)
        let output = directory.appendingPathComponent("sample.txt")
        let captured: Sample600Capture
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            captured = capture(output)
        } catch { captured = .init("temporary-output-error") }
        let report = Self.report(captured)
        try? manager.removeItem(at: directory)
        let removed = !manager.fileExists(atPath: directory.path)
        let (done, waiting) = lock.withLock {
            var done = Sample600Result(status: removed ? report.status : "cleanup-error", text: report.text,
                triggerJob: job, childPID: captured.childPID, targetPID: getpid(), joined: captured.joined,
                rawRemoved: removed, attempts: 1, queuedToEntryMilliseconds: Self.milliseconds(
                    triggerEntry.flatMap { entered in trigger.map { $0.1.duration(to: entered) } }))
            done.lifecycle = lifecycle + captured.lifecycle + [.init(name: "report.completed", instant: now())]
            result = done; running = false
            let saved = waiters; waiters.removeAll(); return (done, saved)
        }
        // Complete only after child reap, parsing and private-file cleanup, even on failure.
        completion()
        for waiter in waiting { waiter.resume(returning: done) }
    }
    private static func milliseconds(_ duration: Duration?) -> Double? {
        duration.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
    }
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var stamps: [Sample600Stamp] = []
        let now: @Sendable () -> ContinuousClock.Instant
        init(_ now: @escaping @Sendable () -> ContinuousClock.Instant) { self.now = now }
        func record(_ name: String, at: ContinuousClock.Instant? = nil, pid: Int32? = nil,
                    result: Int32? = nil, error: Int32? = nil) {
            lock.withLock { stamps.append(.init(name: name, instant: at ?? now(), pid: pid,
                signalResult: result, signalErrno: error)) }
        }
        var events: [Sample600Stamp] { lock.withLock { stamps } }
    }
    private final class Child: @unchecked Sendable {
        let process: Process
        let trace: Lifecycle
        let send: @Sendable (Int32, Int32) -> (Int32, Int32)
        private let lock = NSLock()
        private var reaped = false
        private var expired = false
        init(_ process: Process, trace: Lifecycle,
             signal: @escaping @Sendable (Int32, Int32) -> (Int32, Int32)) {
            self.process = process; self.trace = trace; send = signal
        }
        func signal(_ signal: Int32, name: String) {
            lock.withLock {
                let pid = process.processIdentifier
                trace.record("watchdog.\(name).callback", pid: pid)
                guard !reaped, process.isRunning else { return }
                expired = true
                let (result, error) = send(pid, signal) // positive owned PID only
                trace.record("watchdog.\(name).signal", pid: pid, result: result, error: error)
            }
        }
        func finish() -> Bool {
            lock.withLock {
                reaped = true; trace.record("child.reaped", pid: process.processIdentifier)
                return expired
            }
        }
    }
    private static func read(_ url: URL, limit: Int) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        return String(decoding: (try? file.read(upToCount: limit)) ?? Data(), as: UTF8.self)
    }
    private static func run(_ executable: String, arguments: [String], output: URL, budget: Double,
                            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                            signal: @escaping @Sendable (Int32, Int32) -> (Int32, Int32) = { pid, value in
                                let result = Darwin.kill(pid, value)
                                return (result, result == 0 ? 0 : errno)
                            }) -> Sample600Capture {
        guard !Thread.isMainThread else { return .init("launch-on-main-thread") }
        let trace = Lifecycle(now)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let errorFile = output.deletingLastPathComponent().appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let errors = try? FileHandle(forWritingTo: errorFile) else { return .init("temporary-output-error") }
        defer { try? errors.close() }
        // sample can send progress to either stream. Both stay in the private directory.
        process.standardOutput = errors; process.standardError = errors
        trace.record("launch.begin")
        do { try process.run() } catch {
            trace.record("launch.error")
            return .init("launch-error", lifecycle: trace.events)
        }
        let pid = process.processIdentifier
        trace.record("launch.return", pid: pid)
        let child = Child(process, trace: trace, signal: signal)
        // Existing 12s budget starts after run() returns, independently of MainActor/reaper.
        let planned = now()
        trace.record("watchdog.term.deadline", at: planned.advanced(by: .seconds(budget)), pid: pid)
        trace.record("watchdog.kill.deadline", at: planned.advanced(by: .seconds(budget + 0.25)), pid: pid)
        let term = DispatchWorkItem { child.signal(SIGTERM, name: "term") }
        let kill = DispatchWorkItem { child.signal(SIGKILL, name: "kill") }
        watchdog.asyncAfter(deadline: .now() + budget, execute: term)
        watchdog.asyncAfter(deadline: .now() + budget + 0.25, execute: kill)
        process.waitUntilExit()
        let expired = child.finish(); term.cancel(); kill.cancel()
        // Read bounded partial evidence only after reap, including on timeout.
        let progress = read(errorFile, limit: 8192)
        let raw = read(output, limit: 2 * 1024 * 1024)
        let status: String
        if expired { status = "timeout" }
        else if process.terminationStatus != 0 {
            let message = progress.lowercased()
            let denied = ["permission", "not permitted", "task_for_pid", "access denied"].contains { message.contains($0) }
            status = denied ? "permission-denied" : "exit-error"
        } else { status = raw.isEmpty ? "missing-report" : "captured" }
        return .init(status, raw: raw, childPID: pid, progress: progress, lifecycle: trace.events)
    }
    private static func runSample(_ output: URL) -> Sample600Capture {
        run("/usr/bin/sample", arguments: [String(getpid()), "1", "10", "-mayDie", "-file", output.path], output: output, budget: 12)
    }
    static func partialTimeoutForTest(_ output: URL, raw: String,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        signal: @escaping @Sendable (Int32, Int32) -> (Int32, Int32)) -> Sample600Capture {
        // A single owned PID writes partial evidence then execs tail; no descendant survives reap.
        run("/bin/sh", arguments: ["-c", "printf '%s' \"$2\" > \"$1\"; printf '%s\\n' 'Sampling process 123 /Users/secret' 'secret-token-value' >&2; exec /usr/bin/tail -f /dev/null",
            "i600-partial", output.path, raw], output: output, budget: 0.1, now: now, signal: signal)
    }
    static func controlledTimeoutForTest(_ output: URL) -> Sample600Capture {
        run("/usr/bin/tail", arguments: ["-f", "/dev/null"], output: output, budget: 0.1)
    }
    private static func report(_ captured: Sample600Capture) -> Sample600Report {
        guard captured.status == "timeout" else {
            return captured.status == "captured" ? sanitize(captured.raw) : .init(status: captured.status, text: "")
        }
        let parsed = sanitize(captured.raw)
        let availability = captured.raw.isEmpty ? "missing" : (parsed.status == "captured" ? "main-thread" : "unparseable")
        // Progress is an allowlisted phase summary, never arbitrary tool/user text.
        // Unknown lines are explicitly withheld rather than risking private paths or tokens.
        var phases: [String] = []
        for line in captured.progress.prefix(8192).split(separator: "\n") {
            let lower = line.lowercased()
            let phase: String
            if lower.hasPrefix("sampling process") { phase = "sampling" }
            else if lower.hasPrefix("analysis of sampling") { phase = "analysis" }
            else if lower.hasPrefix("sample analysis of process") { phase = "analysis-written" }
            else if lower.contains("task_for_pid") || lower.contains("not permitted") { phase = "permission-denied" }
            else if lower.contains("symbolicat") { phase = "symbolication" }
            else { phase = "unrecognized-redacted" }
            if !phases.contains(phase) { phases.append(phase) }
        }
        let progress = phases.isEmpty ? "progress=missing" : phases.map { "progress: \($0)" }.joined(separator: "\n")
        let header = "[timeout / partial / incomplete] partial-report=\(availability)\n\(progress)\n"
        // Reserve header space so the combined UTF-8 report, not just the graph, is bounded.
        var graph = parsed.text
        while header.utf8.count + graph.utf8.count > maximumBytes { graph.removeLast() }
        return .init(status: "timeout", text: header + graph)
    }
    static func sanitize(_ raw: String) -> Sample600Report {
        var main = false, found = false, kept: [String] = [], truncated = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.contains("Binary Images:") || line.contains("Sort by top of stack") || line.contains("Total number in stack") { break }
            if line.contains("Thread_") {
                if main { break }
                if line.contains("com.apple.main-thread") { main = true; found = true }
                else { continue }
            }
            guard main else { continue }
            guard line.contains("com.apple.main-thread") || line.range(of: #"^\s*[+!:| ]*\d+\s+"#, options: .regularExpression) != nil else { continue }
            var safe = line.replacingOccurrences(of: #"\([^)]*(?:/|[A-Za-z]:\\)[^)]*\)"#, with: "[redacted-path]", options: .regularExpression)
            safe = safe.replacingOccurrences(of: #"(?:[A-Za-z]:[\\/]|/)[^\s)\]]+"#, with: "[redacted-path]", options: .regularExpression)
            safe = safe.replacingOccurrences(of: #"\[0x[0-9a-fA-F]+\]"#, with: "", options: .regularExpression)
            if safe.count > 2000 { safe = String(safe.prefix(2000)); truncated = true }
            if kept.count >= maximumLines - 1 || (kept.joined(separator: "\n").utf8.count + safe.utf8.count + 32) > maximumBytes {
                truncated = true; break
            }
            kept.append(safe)
        }
        guard found else { return .init(status: "no-main-thread", text: "") }
        if truncated { kept.append("[truncated]") }
        return .init(status: "captured", text: kept.joined(separator: "\n"))
    }
}
