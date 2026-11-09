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
        #expect(result.text.isEmpty)
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
