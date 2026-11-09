import AppKit
import Foundation
import Testing
import Darwin
import MadoCore
import MadoApplication
import MadoInfrastructure

private let sample600Fixture = """
Process: private /Users/secret/header
Call graph:
    10 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
      10 issue600SamplerHeldMainActorFrame (in MadoAppTests) + 12 [0x123] /Users/secret/source.swift:10
        10 semaphore_wait_trap (in libsystem_kernel.dylib) + 8
    1 Thread_2 DispatchQueue_2: other-private-thread
      1 doNotExposeOtherThread /private/secret/file
Binary Images:
    0x1000 /Users/secret/binary
"""

private final class Sample600Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        let pending = lock.withLock { opened = true; let w = waiters; waiters = []; return w }
        for waiter in pending { waiter.resume() }
    }
    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                let resume = lock.withLock { if opened { return true }; waiters.append(waiter); return false }
                if resume { waiter.resume() }
            }
        } onCancel: { self.open() }
        try Task.checkCancellation()
    }
}

private final class Sample600CaptureGate: @unchecked Sendable {
    let entered = Sample600Latch()
    private let release = DispatchSemaphore(value: 0)
    func capture(_ output: URL) -> Sample600Capture {
        entered.open(); release.wait()
        return .init("captured", raw: sample600Fixture)
    }
    func open() { release.signal() }
}

private func sample600Job(_ sampler: ScanLag600Sampler) throws -> (FolderOpenStageRecorder, FolderOpenStageEvent) {
    let events = FolderOpen600Events()
    let recorder = FolderOpenStageRecorder(observer: { event in events.append(event); sampler.observe(event) }, extended: true)
    let job = try #require(recorder.queuedJob("scan.task"))
    let queued = try #require(events.events.first { $0.outcome == .queued })
    return (job, queued)
}

@MainActor @inline(never)
private func issue600SamplerHeldMainActorFrame(_ release: DispatchSemaphore, arm: () throws -> Void) rethrows {
    try arm()
    release.wait()
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerCapturesHeldMainActorFrame() async throws {
    let release = DispatchSemaphore(value: 0)
    let sampler = ScanLag600Sampler(onCompletion: { release.signal() })
    let (a, _) = try sample600Job(sampler)
    a.entered()
    var held: (FolderOpenStageRecorder, FolderOpenStageEvent)?
    try issue600SamplerHeldMainActorFrame(release) {
        let pair = try sample600Job(sampler)
        held = pair
        let id = try #require(pair.1.jobID)
        let original = sampler.state().pending[id]
        a.entered()
        sampler.observe(pair.1)
        #expect(sampler.state().pending[id] == original)
    }
    let (b, queued) = try #require(held)
    let id = try #require(queued.jobID)
    b.entered()
    let (_, c) = try sample600Job(sampler)
    #expect(sampler.state().pending[c.jobID!] == nil)
    let result = await sampler.finish()
    #expect(result.status == "captured", "Sampler unavailable: \(result.status)")
    #expect(result.text.contains("com.apple.main-thread"))
    #expect(result.text.contains("issue600SamplerHeldMainActorFrame"))
    #expect(result.triggerJob == id)
    #expect(result.targetPID == getpid())
    #expect(result.childPID != nil)
    #expect(result.joined && result.rawRemoved)
    #expect(result.attempts == 1)
    #expect(result.text.utf8.count <= ScanLag600Sampler.maximumBytes)
    #expect(!result.text.contains("Binary Images") && !result.text.contains("/Users/"))
}

@Test(.timeLimit(.minutes(3)))
func issue600SamplerRedactsAndBoundsReports() {
    let report = ScanLag600Sampler.sanitize(sample600Fixture)
    #expect(report.status == "captured")
    #expect(report.text.contains("issue600SamplerHeldMainActorFrame"))
    #expect(report.text.contains("semaphore_wait_trap"))
    for forbidden in ["/Users/", "/private/", "Binary Images", "Process:", "doNotExposeOtherThread", "other-private-thread"] {
        #expect(!report.text.contains(forbidden))
    }
    let privateFrame = "    1 privateFrame (C:\\Users\\secret\\file.swift) /Users/secret/file /private/secret/file\n"
    let huge = "Call graph:\n  1 Thread_1 DispatchQueue_1: com.apple.main-thread\n" + String(repeating: privateFrame + "    1 " + String(repeating: "界", count: 2000) + "\n", count: 1000) + "Binary Images:\n"
    let bounded = ScanLag600Sampler.sanitize(huge)
    #expect(bounded.text.utf8.count <= ScanLag600Sampler.maximumBytes)
    #expect(bounded.text.split(separator: "\n").count <= ScanLag600Sampler.maximumLines)
    #expect(!bounded.text.contains("secret"))
    #expect(bounded.text.contains("truncated"))
    for malformed in ["", "Process: /Users/private\nBinary Images:\n", "Call graph:\n  1 Thread_2 not-main\n"] {
        #expect(ScanLag600Sampler.sanitize(malformed).status == "no-main-thread")
    }
}

@MainActor private struct Sample600FolderFixture {
    let base: URL, folder: URL, files: FileAccess, root: AccessRootID
    init() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sample600-\(UUID())", isDirectory: true)
        folder = base.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        for index in 0..<3 { try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("\(index).png")) }
        let system = SystemSecurityScope()
        files = try FileAccess(scope: system, bookmarks: system,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "sample600")
        root = try await files.grant(folder: folder)
    }
    func coordinator() -> FolderScanCoordinator { FolderScanCoordinator(access: files, scanner: FolderBrowser(), trace: nil) }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerSuppressesEnteredCanceledAndDisabledCases() async throws {
    for mode in ["entry", "cancel", "disabled"] {
        let sampler = ScanLag600Sampler(enabled: mode != "disabled", manualTrigger: true)
        let (job, event) = try sample600Job(sampler)
        let id = try #require(event.jobID)
        if mode == "entry" { job.entered() }
        else { sampler.cancel(id) }
        #expect(!sampler.fireForTest(id))
        let fixture = try await Sample600FolderFixture(); defer { fixture.remove() }
        let scan = fixture.coordinator(); defer { scan.end() }
        try await scan.begin(folder: fixture.folder, rootID: fixture.root).value
        #expect(scan.sourceSnapshot?.isComplete == true)
        #expect(Set(scan.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
        let result = await sampler.finish()
        #expect(result.status == "not-triggered")
        #expect(result.attempts == 0 && result.childPID == nil)
        #expect(result.joined && result.rawRemoved)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerCaseQuotaSurvivesMultipleOpeningIdentities() async throws {
    let gate = Sample600CaptureGate(); defer { gate.open() }
    let sampler = ScanLag600Sampler(manualTrigger: true, capture: { gate.capture($0) })
    let (a, _) = try sample600Job(sampler); a.entered()
    #expect(!sampler.state().spent)
    let (b, event) = try sample600Job(sampler)
    let id = try #require(event.jobID)
    let deadline = sampler.state().pending[id]
    a.entered(); sampler.observe(event)
    #expect(sampler.state().pending[id] == deadline)
    #expect(sampler.fireForTest(id))
    try await gate.entered.wait()
    b.entered(); sampler.cancel(id); sampler.observe(event)
    #expect(!sampler.fireForTest(id))
    #expect(sampler.state().attempts == 1 && sampler.state().running)
    let (_, c) = try sample600Job(sampler)
    #expect(sampler.state().pending[c.jobID!] == nil)
    gate.open()
    let result = await sampler.finish()
    #expect(result.status == "captured" && result.text.contains("issue600SamplerHeldMainActorFrame"))
    #expect(result.triggerJob == id && result.attempts == 1)
    #expect(result.joined && result.rawRemoved && !sampler.state().running)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerErrorsAlwaysReleaseAndDrain() async throws {
    for status in ["launch-error", "exit-error", "timeout", "captured"] {
        let sampler = ScanLag600Sampler(manualTrigger: true, capture: { _ in .init(status) })
        let (_, event) = try sample600Job(sampler)
        #expect(sampler.fireForTest(event.jobID!))
        let result = await sampler.finish()
        #expect(result.status == (status == "captured" ? "no-main-thread" : status))
        #expect(result.joined && result.rawRemoved && !sampler.state().running)
        #expect(status == "timeout" ? result.text.contains("partial-report=missing") : result.text.isEmpty)
    }
    let timeout = ScanLag600Sampler(manualTrigger: true, capture: { ScanLag600Sampler.controlledTimeoutForTest($0) })
    let (_, event) = try sample600Job(timeout)
    #expect(timeout.fireForTest(event.jobID!))
    let drained = await timeout.finish()
    #expect(drained.status == "timeout")
    #expect(drained.childPID != nil && drained.joined && drained.rawRemoved)
    #expect(!timeout.state().running)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerJoinCannotChangeFrozenScanOutcome() async throws {
    for initiallyMissing in [false, true] {
        let fixture = try await Sample600FolderFixture(); defer { fixture.remove() }
        let scan = fixture.coordinator(); defer { scan.end() }
        let absent = fixture.folder.appendingPathComponent("missing-child", isDirectory: true)
        _ = await scan.begin(folder: initiallyMissing ? absent : fixture.folder, rootID: fixture.root).result
        let frozenOutcome = scan.sourceSnapshot?.isComplete == true && scan.failure == nil
        #expect(frozenOutcome == !initiallyMissing)
        let gate = Sample600CaptureGate(); defer { gate.open() }
        let sampler = ScanLag600Sampler(manualTrigger: true, capture: { gate.capture($0) })
        let (_, event) = try sample600Job(sampler)
        #expect(sampler.fireForTest(event.jobID!))
        try await gate.entered.wait()
        let changed = scan.begin(folder: initiallyMissing ? fixture.folder : absent, rootID: fixture.root)
        let transition = Task { @MainActor in _ = await changed.result; gate.open() }
        defer { transition.cancel(); gate.open() }
        let result = await sampler.finish()
        await transition.value
        let liveOutcome = scan.sourceSnapshot?.isComplete == true && scan.failure == nil
        #expect(liveOutcome == initiallyMissing)
        #expect(frozenOutcome == !initiallyMissing)
        if initiallyMissing {
            #expect(Set(scan.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
        }
        #expect(result.joined && result.rawRemoved)
        #expect(result.status == "captured")
    }
}

@Test(.timeLimit(.minutes(3)))
func issue600SamplerReportsMissedTriggerWhenEntryIsAlreadyLate() async throws {
    let sampler = ScanLag600Sampler(manualTrigger: true)
    let (_, queued) = try sample600Job(sampler)
    let late = FolderOpenStageEvent(controllerID: queued.controllerID, jobID: queued.jobID,
        spanID: nil, kind: .job, isMainThread: false, openingID: queued.openingID,
        stage: "scan.task", outcome: .entered, instant: queued.instant.advanced(by: .seconds(2)),
        elapsed: .seconds(2), reason: nil)
    sampler.observe(late)
    let result = await sampler.finish()
    #expect(result.status == "lag-observed-trigger-missed")
    #expect(result.queuedToEntryMilliseconds == 2000)
    #expect(result.childPID == nil && result.attempts == 0)
    #expect(result.text.isEmpty && result.joined && result.rawRemoved)
}


@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerRetainsEntryAfterReservationAndFinish() async throws {
    let gate = Sample600CaptureGate(); defer { gate.open() }
    let origin = ContinuousClock.now
    let sampler = ScanLag600Sampler(manualTrigger: true, capture: { gate.capture($0) }, now: { origin })
    let (_, queued) = try sample600Job(sampler)
    #expect(sampler.fireForTest(queued.jobID!))
    try await gate.entered.wait()
    let finishing = Task { await sampler.finish() }
    await Task.yield()
    for (id, seconds) in [(UUID(), 9), (queued.jobID!, 2), (queued.jobID!, 3)] {
        sampler.observe(FolderOpenStageEvent(controllerID: queued.controllerID, jobID: id,
            spanID: nil, kind: .job, isMainThread: false, openingID: queued.openingID,
            stage: "scan.task", outcome: .entered, instant: queued.instant.advanced(by: .seconds(seconds)),
            elapsed: .seconds(seconds), reason: nil))
    }
    gate.open()
    let result = await finishing.value
    #expect(result.queuedToEntryMilliseconds == 2000)
    #expect(result.attempts == 1 && result.triggerJob == queued.jobID)
    #expect(result.lifecycle.first { $0.name == "trigger.queued" }?.instant == queued.instant)
    #expect(result.lifecycle.first { $0.name == "timer.executed" }?.instant == origin)
    #expect(result.lifecycle.first { $0.name == "reservation" }?.instant == origin)
    #expect(result.lifecycle.filter { $0.name == "trigger.entered" }.map(\.instant) == [queued.instant.advanced(by: .seconds(2))])
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerTimeoutKeepsPartialAndAlignedLifecycle() async throws {
    let origin = ContinuousClock.now
    let sampler = ScanLag600Sampler(manualTrigger: true, capture: { output in
        ScanLag600Sampler.partialTimeoutForTest(output, raw: sample600Fixture, now: { origin }) { pid, signal in
            if signal == SIGTERM { return (-1, EPERM) }
            let result = Darwin.kill(pid, signal)
            return (result, result == 0 ? 0 : errno)
        }
    }, now: { origin })
    let (_, queued) = try sample600Job(sampler)
    #expect(sampler.fireForTest(queued.jobID!))
    let result = await sampler.finish()
    #expect(result.status == "timeout")
    #expect(result.text.contains("timeout / partial / incomplete"))
    #expect(result.text.contains("issue600SamplerHeldMainActorFrame"))
    #expect(result.text.contains("progress: sampling"))
    #expect(!result.text.contains("secret") && !result.text.contains("/Users/") && !result.text.contains("Binary Images"))
    #expect(result.text.utf8.count <= ScanLag600Sampler.maximumBytes)
    #expect(result.joined && result.rawRemoved)
    let pid = try #require(result.childPID)
    #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    let stamps = result.lifecycle
    for name in ["launch.begin", "launch.return", "watchdog.term.callback", "watchdog.kill.callback", "child.reaped", "report.completed"] {
        #expect(stamps.first { $0.name == name }?.instant == origin)
    }
    #expect(stamps.first { $0.name == "launch.return" }?.pid == pid)
    #expect(stamps.first { $0.name == "watchdog.term.deadline" }?.instant == origin.advanced(by: .seconds(0.1)))
    #expect(stamps.first { $0.name == "watchdog.kill.deadline" }?.instant == origin.advanced(by: .seconds(0.35)))
    let term = try #require(stamps.first { $0.name == "watchdog.term.signal" })
    #expect(term.pid == pid && term.signalResult == -1 && term.signalErrno == EPERM)
    let killed = try #require(stamps.first { $0.name == "watchdog.kill.signal" })
    #expect(killed.pid == pid && killed.signalResult == 0 && killed.signalErrno == 0)
    let reap = try #require(stamps.firstIndex { $0.name == "child.reaped" })
    let completed = try #require(stamps.firstIndex { $0.name == "report.completed" })
    #expect(reap < completed)
}

@Test(.timeLimit(.minutes(3)), arguments: ["", "Thread_2 unrelated", sample600Fixture + String(repeating: "界", count: 20000)]) @MainActor
func issue600SamplerTimeoutOutputIsExplicitAndBounded(raw: String) async throws {
    let sampler = ScanLag600Sampler(manualTrigger: true, capture: { _ in
        .init("timeout", raw: raw, progress: "Sampling process 123 /Users/secret\nsecret-token-value\n" + String(repeating: "private", count: 10000))
    })
    let (_, queued) = try sample600Job(sampler)
    #expect(sampler.fireForTest(queued.jobID!))
    let result = await sampler.finish()
    #expect(result.status == "timeout")
    #expect(result.text.contains("timeout / partial / incomplete"))
    #expect(result.text.contains(raw.isEmpty ? "partial-report=missing" : (raw.contains("com.apple.main-thread") ? "partial-report=main-thread" : "partial-report=unparseable")))
    #expect(!result.text.contains("secret") && !result.text.contains("private"))
    #expect(result.text.utf8.count <= ScanLag600Sampler.maximumBytes)
    #expect(result.joined && result.rawRemoved)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerAutomaticTimerAndSharedOrigin() async throws {
    let origin = ContinuousClock.now
    let sampler = ScanLag600Sampler(milliseconds: 1, capture: { _ in .init("captured", raw: sample600Fixture) })
    let (_, queued) = try sample600Job(sampler)
    // Completion follows the actual background timer; no MainActor polling deadline.
    while !sampler.state().spent { try await Task.sleep(for: .milliseconds(1)) }
    let result = await sampler.finish()
    let timer = try #require(result.lifecycle.first { $0.name == "timer.executed" })
    let reserved = try #require(result.lifecycle.first { $0.name == "reservation" })
    #expect(result.lifecycle.filter { $0.name == "timer.executed" }.count == 1)
    #expect(queued.instant <= timer.instant && timer.instant <= reserved.instant)
    let fixed = Sample600Stamp(name: "launch.begin", instant: origin.advanced(by: .seconds(2)))
    #expect(fixed.line(relativeTo: origin).contains("shared=+2.0 seconds"))
    #expect(fixed.line(relativeTo: origin.advanced(by: .seconds(1))).contains("shared=+1.0 seconds"))
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SamplerTriggerCannotInheritAnotherJobsLag() async throws {
    let sampler = ScanLag600Sampler(manualTrigger: true, capture: { _ in .init("timeout") })
    let (_, a) = try sample600Job(sampler)
    sampler.observe(FolderOpenStageEvent(controllerID: a.controllerID, jobID: a.jobID,
        spanID: nil, kind: .job, isMainThread: false, openingID: a.openingID,
        stage: "scan.task", outcome: .entered, instant: a.instant.advanced(by: .seconds(2)),
        elapsed: .seconds(2), reason: nil))
    let (_, b) = try sample600Job(sampler)
    #expect(sampler.fireForTest(b.jobID!))
    let result = await sampler.finish()
    #expect(result.triggerJob == b.jobID)
    #expect(result.queuedToEntryMilliseconds == nil)
}
