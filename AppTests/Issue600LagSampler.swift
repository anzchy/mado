import Foundation
import Darwin

struct Sample600Capture: Sendable {
    let status: String
    let raw: String
    let childPID: Int32?
    let joined: Bool
    init(_ status: String, raw: String = "", childPID: Int32? = nil, joined: Bool = true) {
        self.status = status; self.raw = raw; self.childPID = childPID; self.joined = joined
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
         capture: Capture? = nil, onCompletion: @escaping @Sendable () -> Void = {}) {
        self.enabled = enabled; self.milliseconds = milliseconds; manual = manualTrigger
        self.capture = capture ?? { Self.runSample($0) }
        completion = onCompletion
    }
    func observe(_ event: FolderOpenStageEvent) {
        guard event.kind == .job, event.stage == "scan.task", let id = event.jobID else { return }
        if event.outcome != .queued {
            lock.withLock {
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
            pending[id] = Pending(deadline: event.instant.advanced(by: .milliseconds(milliseconds)), work: work)
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
            guard enabled, !closed, !spent, pending[job] != nil else { return false }
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
        let report = captured.status == "captured" ? Self.sanitize(captured.raw) : .init(status: captured.status, text: "")
        try? manager.removeItem(at: directory)
        let removed = !manager.fileExists(atPath: directory.path)
        let done = Sample600Result(status: removed ? report.status : "cleanup-error", text: report.text,
            triggerJob: job, childPID: captured.childPID, targetPID: getpid(), joined: captured.joined,
            rawRemoved: removed, attempts: 1, queuedToEntryMilliseconds: lock.withLock { Self.milliseconds(maximumLateEntry) })
        let waiting = lock.withLock {
            result = done; running = false
            let saved = waiters; waiters.removeAll(); return saved
        }
        // Complete only after child reap, parsing and private-file cleanup, even on failure.
        completion()
        for waiter in waiting { waiter.resume(returning: done) }
    }
    private static func milliseconds(_ duration: Duration?) -> Double? {
        duration.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
    }
    private final class Child: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var reaped = false
        private var expired = false
        init(_ process: Process) { self.process = process }
        func signal(_ signal: Int32) {
            lock.withLock {
                guard !reaped, process.isRunning else { return }
                expired = true
                _ = Darwin.kill(process.processIdentifier, signal) // positive PID: never the xctest group
            }
        }
        func finish() -> Bool { lock.withLock { reaped = true; return expired } }
    }
    private static func run(_ executable: String, arguments: [String], output: URL, budget: Double) -> Sample600Capture {
        guard !Thread.isMainThread else { return .init("launch-on-main-thread") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        let errorFile = output.deletingLastPathComponent().appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let errors = try? FileHandle(forWritingTo: errorFile) else { return .init("temporary-output-error") }
        defer { try? errors.close() }
        process.standardError = errors
        do { try process.run() } catch { return .init("launch-error") }
        let child = Child(process)
        // Independent of both the MainActor and the blocking reaper queue.
        let term = DispatchWorkItem { child.signal(SIGTERM) }
        let kill = DispatchWorkItem { child.signal(SIGKILL) }
        watchdog.asyncAfter(deadline: .now() + budget, execute: term)
        watchdog.asyncAfter(deadline: .now() + budget + 0.25, execute: kill)
        process.waitUntilExit()
        let expired = child.finish(); term.cancel(); kill.cancel()
        let pid = process.processIdentifier
        if expired { return .init("timeout", childPID: pid) }
        if process.terminationStatus != 0 {
            let data = (try? Data(contentsOf: errorFile)) ?? Data()
            let message = String(decoding: data.prefix(8192), as: UTF8.self).lowercased()
            let denied = ["permission", "not permitted", "task_for_pid", "access denied"].contains { message.contains($0) }
            return .init(denied ? "permission-denied" : "exit-error", childPID: pid)
        }
        guard let file = try? FileHandle(forReadingFrom: output) else { return .init("missing-report", childPID: pid) }
        defer { try? file.close() }
        let data = (try? file.read(upToCount: 2 * 1024 * 1024)) ?? Data()
        return .init("captured", raw: String(decoding: data, as: UTF8.self), childPID: pid)
    }
    private static func runSample(_ output: URL) -> Sample600Capture {
        run("/usr/bin/sample", arguments: [String(getpid()), "1", "10", "-mayDie", "-file", output.path], output: output, budget: 12)
    }
    static func controlledTimeoutForTest(_ output: URL) -> Sample600Capture {
        run("/usr/bin/tail", arguments: ["-f", "/dev/null"], output: output, budget: 0.1)
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
