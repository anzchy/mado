import Foundation
import Testing
import MadoCore
@testable import MadoApplication

/// #238 (P3-17c D3): 「读取失败」 (24F-A) and its boundary with page 26.
enum ReadFailedErrorKind: CaseIterable, Sendable {
    case io, denied, cocoaDenied, gone
    var error: any Error & Sendable {
        switch self {
        case .io: POSIXError(.EIO)
        case .denied: POSIXError(.EACCES)
        case .cocoaDenied: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        case .gone: POSIXError(.ENOENT)
        }
    }
    var reason: String {
        switch self {
        case .io, .gone: "Folder scan failed"
        case .denied, .cocoaDenied: "Folder access denied"
        }
    }
}

@MainActor final class ReadFailedHost: FolderScanHost, ViewerSessionNavigationHost, ViewerInputHost {
    var log: [String] = []
    var openRequests = 0
    var hasImage = false
    var canNavigate = true
    func openFolderImage(_ url: URL, rootID: AccessRootID) { log.append("open-\(url.lastPathComponent)") }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { log.append("remember") }
    func clearFolderImageForNoMatches() { log.append("clear") }
    func folderScanDidComplete(count: Int) { log.append("complete-\(count)") }
    func folderScanDidStart() { log.append("start") }
    func folderScanDidEnd() { log.append("end") }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) { }
    func showInputNotice(_ notice: ViewerInputNotice) { }
    func promptForInputFolder(_ folder: URL) { }
    func navigate(_ direction: NavigationDirection) { }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func requestOpen() { openRequests += 1 }
    func applyFocus(_ focus: FocusContext) { }
    func showInspector(_ visible: Bool) { }
    /// Events after the last `start`, which the scan under test owns.
    var sinceStart: [String] { Array(log[((log.lastIndex(of: "start") ?? -1) + 1)...]) }
}

/// Same domain and code, since POSIXError and NSError bridge.
func readFailedSameError(_ lhs: (any Error)?, _ rhs: any Error) -> Bool {
    guard let lhs else { return false }
    let a = lhs as NSError, b = rhs as NSError
    return a.domain == b.domain && a.code == b.code
}

@MainActor private func readFailedScene(_ name: String = "待整理")
    -> (FolderScanFixture, FolderScanCoordinator, ViewerSession, ReadFailedHost, URL) {
    let fixture = FolderScanFixture(), host = ReadFailedHost()
    let session = ViewerSession(host: host), coordinator = fixture.coordinator
    session.folderScan = coordinator; coordinator.host = host
    return (fixture, coordinator, session, host, fixture.root.appendingPathComponent(name))
}

// MARK: WI-1 — the failure state carries the folder name; a folder-entry failure keeps nothing partial.

@Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2, 3], ReadFailedErrorKind.allCases)
@MainActor func readFailedFolderEntryNeverPublishesPartialAsComplete(cut: Int, kind: ReadFailedErrorKind) async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    for index in 0..<cut {
        try await fixture.scanner.deliver(["img\(index).png"])
        #expect(!host.log.contains { $0.hasPrefix("complete-") }, "batch \(index)")
        #expect(coordinator.completedImageCount == nil, "batch \(index)")
    }
    await fixture.scanner.finish(failing: true, error: kind.error)
    var thrown: (any Error)?
    do { try await task.value } catch { thrown = error }
    #expect(readFailedSameError(thrown, kind.error))
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil)
    #expect(coordinator.completedImageCount == nil && !session.hasFolderSource)
    #expect(coordinator.failure != nil && !coordinator.isScanning && !coordinator.isReadingFolder)
    #expect(session.imageStatus == .folderScanFailed(kind.reason, "待整理"))
    #expect(host.sinceStart == ["end"])
    #expect(!host.log.contains { $0.hasPrefix("complete-") || $0.hasPrefix("open-") })
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedAcquireFailureIsAReadFailureWithNoLease() async throws {
    let fixture = FolderScanFixture(fails: true), host = ReadFailedHost()
    let session = ViewerSession(host: host), coordinator = fixture.coordinator
    session.folderScan = coordinator; coordinator.host = host
    let folder = fixture.root.appendingPathComponent("待整理")
    await #expect(throws: FolderScanTestError.expected) { try await coordinator.begin(folder: folder, rootID: fixture.id).value }
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil)
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    #expect(host.sinceStart == ["end"])
    #expect(await fixture.access.balance == [0, 0])
    #expect(await fixture.scanner.startedCount == 0)
}

@Test(.timeLimit(.minutes(2)), arguments: ["待整理", "A"])
@MainActor func readFailedStatusNamesTheFolderNotACount(name: String) async throws {
    let (fixture, coordinator, session, _, folder) = readFailedScene(name)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", name))
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedFolderEntryRetryRescansWithoutSnapshot() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    _ = coordinator.setRecursiveEnabled(true)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"])
    coordinator.setConditions(.init(sort: .name, direction: .descending, selectedExtensions: ["png"]))
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(coordinator.sourceSnapshot == nil)
    let before = coordinator.conditions
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    #expect(await fixture.scanner.startedCount == 2)
    #expect(await fixture.scanner.folder(at: 1) == folder)
    #expect(await fixture.scanner.options(at: 1).recursive)
    #expect(coordinator.conditions == before)
    #expect(coordinator.isReadingFolder && session.imageStatus == .readingFolder)
    #expect(await fixture.access.requests == [.root(fixture.id, file: folder), .root(fixture.id, file: folder)])
    #expect(host.log.last == "start")
    coordinator.cancel()
    await fixture.scanner.finish(1); _ = try? await retry.value
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 1, 3])
@MainActor func readFailedImageFirstKeepsKnownImagesNavigable(count: Int) async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let coordinator = fixture.coordinator, session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let input = fixture.folder.appendingPathComponent("img2.png")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    if count > 0 { try await fixture.scanner.deliver(count == 1 ? ["img2.png"] : ["img1.png", "img2.png", "img10.png"]) }
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(coordinator.snapshot?.entries.count == count)
    #expect(coordinator.canMove(.next) == (count == 3) && coordinator.canMove(.previous) == (count == 3))
    #expect(coordinator.currentURL == input)
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "A"))
    #expect(host.opens.isEmpty)
    #expect(await fixture.access.balance == [1, 1])
}

// MARK: WI-2 — the Access Root is checked before a failure is published.

/// Fake for the App's root-loss port (AccessMonitor lives in App). `fixed` answers at once; otherwise `answer` resumes.
@MainActor final class RootLossGate {
    var calls: [(AccessRootID, any Error)] = []
    var fixed: Bool?
    private var pending: CheckedContinuation<Bool, Never>?
    init(fixed: Bool? = nil) { self.fixed = fixed }
    func check(_ id: AccessRootID, _ error: any Error) async -> Bool {
        calls.append((id, error))
        if let fixed { return fixed }
        return await withCheckedContinuation { pending = $0 }
    }
    /// On the shared cancellation-driven wait (#398): a check that is never called fails the test at this wait
    /// instead of hanging it or returning silently.
    func waitForCall(_ count: Int = 1, fileID: String = #fileID, line: Int = #line) async throws {
        try await waitUntil("root-loss check called \(count) time(s)", fileID: fileID, line: line) { calls.count >= count }
    }
    func answer(lost: Bool) { pending?.resume(returning: lost); pending = nil }
    func install(on coordinator: FolderScanCoordinator) {
        coordinator.rootLossCheck = { [self] id, error in await check(id, error) }
    }
}

private func readFailedIsScanFailure(_ status: ViewerImageStatus) -> Bool {
    if case .folderScanFailed = status { return true }
    return false
}

enum RootCheckOutcome: CaseIterable, Sendable { case none, readable, lost }

@Test(.timeLimit(.minutes(2)), arguments: RootCheckOutcome.allCases, [0, 2])
@MainActor func readFailedRootCheckOutcomeTable(outcome: RootCheckOutcome, cut: Int) async throws {
    for imageFirst in [false, true] {
        let fixture = FolderScanFixture(), host = ReadFailedHost(), trace = FolderFixTrace()
        let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
        let session = ViewerSession(host: host)
        session.folderScan = coordinator; coordinator.host = host
        let gate = RootLossGate(fixed: outcome == .lost)
        if outcome != .none { gate.install(on: coordinator) }
        let folder = fixture.root.appendingPathComponent("待整理")
        let input = imageFirst ? folder.appendingPathComponent("img2.png") : nil
        let task = coordinator.begin(folder: folder, rootID: fixture.id, input: input)
        await fixture.scanner.waitForStart()
        if cut > 0 { try await fixture.scanner.deliver(["img1.png", "img2.png"]) }
        await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
        var thrown: (any Error)?
        do { try await task.value } catch { thrown = error }
        let step = "\(outcome) cut \(cut) imageFirst \(imageFirst)"
        #expect(readFailedSameError(thrown, ReadFailedErrorKind.io.error), "\(step)")
        #expect((coordinator.failure != nil) == (outcome != .lost), "\(step)")
        #expect(!coordinator.isScanning, "\(step)")
        if outcome == .lost {
            #expect(!readFailedIsScanFailure(session.imageStatus), "\(step)")
            #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil, "\(step)")
        } else {
            #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"), "\(step)")
            #expect((coordinator.sourceSnapshot == nil) == !imageFirst || cut == 0, "\(step)")
        }
        #expect(host.sinceStart == ["end"], "\(step)")
        #expect(!host.log.contains { $0.hasPrefix("complete-") }, "\(step)")
        #expect(gate.calls.count == (outcome == .none ? 0 : 1), "\(step)")
        #expect(trace.events.last == "failed-1" && trace.events.filter { $0.hasSuffix("-1") && !$0.hasPrefix("begin") && !$0.hasPrefix("first") }.count == 1, "\(step)")
        #expect(await fixture.access.balance == [1, 1], "\(step)")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRootCheckPendingKeepsReadingState() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"]); try await fixture.scanner.deliver(["img2.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    try await gate.waitForCall(1)
    for _ in 0..<3 {
        #expect(session.imageStatus == .readingFolder)
        #expect(coordinator.isReadingFolder && coordinator.failure == nil && coordinator.isScanning)
        #expect(host.sinceStart.isEmpty)
        await Task.yield()
    }
    #expect(gate.calls.first?.0 == fixture.id)
    #expect(readFailedSameError(gate.calls.first?.1, ReadFailedErrorKind.io.error))
    gate.answer(lost: false)
    _ = try? await task.value
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    #expect(coordinator.sourceSnapshot == nil && host.sinceStart == ["end"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRootLostHandsOffWithoutPublishingFailure() async throws {
    let fixture = FolderScanFixture(), host = ReadFailedHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: fixture.root.appendingPathComponent("待整理"), rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png", "img3.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.gone.error)
    try await gate.waitForCall(1)
    gate.answer(lost: true)
    var thrown: (any Error)?
    do { try await task.value } catch { thrown = error }
    #expect(readFailedSameError(thrown, ReadFailedErrorKind.gone.error))
    #expect(coordinator.failure == nil && coordinator.failureReason == nil)
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil && !coordinator.isScanning)
    #expect(!readFailedIsScanFailure(session.imageStatus))
    #expect(coordinator.retry() == nil)
    #expect(host.sinceStart == ["end"])
    #expect(trace.events == ["begin-1", "first-3", "failed-1"])
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRootReadablePublishesReadFailed() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.denied.error)
    try await gate.waitForCall(1)
    gate.answer(lost: false)
    _ = try? await task.value
    #expect(gate.calls.count == 1)
    #expect(session.imageStatus == .folderScanFailed("Folder access denied", "待整理"))
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil && coordinator.completedImageCount == nil)
    #expect(host.sinceStart == ["end"])
}

struct ReadFailedProjection: Equatable {
    let status: ViewerImageStatus, failureReason: String?, conditions: FolderViewConditions, recursive: Bool
    let scanning: Bool, reading: Bool, snapshotNil: Bool, sourceNil: Bool, count: Int?, hasSource: Bool
}
@MainActor func readFailedProject(_ coordinator: FolderScanCoordinator, _ session: ViewerSession) -> ReadFailedProjection {
    ReadFailedProjection(status: session.imageStatus, failureReason: coordinator.failureReason,
        conditions: coordinator.conditions, recursive: coordinator.recursiveEnabled,
        scanning: coordinator.isScanning, reading: coordinator.isReadingFolder,
        snapshotNil: coordinator.snapshot == nil, sourceNil: coordinator.sourceSnapshot == nil,
        count: coordinator.completedImageCount, hasSource: session.hasFolderSource)
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 3])
@MainActor func readFailedWithoutRootCheckMatchesReadableCheck(cut: Int) async throws {
    var projections: [ReadFailedProjection] = [], logs: [[String]] = []
    for checked in [false, true] {
        let (fixture, coordinator, session, host, folder) = readFailedScene()
        if checked { RootLossGate(fixed: false).install(on: coordinator) }
        let task = coordinator.begin(folder: folder, rootID: fixture.id)
        await fixture.scanner.waitForStart()
        if cut > 0 { try await fixture.scanner.deliver(["img1.png", "img2.png", "img3.png"]) }
        await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
        _ = try? await task.value
        projections.append(readFailedProject(coordinator, session)); logs.append(host.log)
    }
    #expect(projections[0] == projections[1])
    #expect(logs[0] == logs[1])
}

enum ReadFailedEnding: CaseIterable, Sendable { case failure, cancel, end, replaced, cancellationError }

@Test(.timeLimit(.minutes(2)), arguments: ReadFailedEnding.allCases)
@MainActor func readFailedRootCheckRunsOncePerFailureNotOnCancel(ending: ReadFailedEnding) async throws {
    let (fixture, coordinator, session, _, folder) = readFailedScene()
    let gate = RootLossGate(fixed: false); gate.install(on: coordinator)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"])
    var replacement: Task<Void, any Error>?
    switch ending {
    case .failure: await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    case .cancel: coordinator.cancel(); await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    case .end: coordinator.end(); await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    case .replaced:
        replacement = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    case .cancellationError: await fixture.scanner.finish(failing: true, error: CancellationError())
    }
    _ = try? await task.value
    if ending == .failure {
        #expect(gate.calls.count == 1)
        #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    } else {
        #expect(gate.calls.isEmpty, "\(ending)")
        #expect(coordinator.failure == nil && !readFailedIsScanFailure(session.imageStatus), "\(ending)")
    }
    if let replacement {
        await fixture.scanner.waitForStart(1); await fixture.scanner.finish(1); _ = try? await replacement.value
        #expect(await fixture.access.balance == [2, 2])
    } else {
        #expect(await fixture.access.balance == [1, 1])
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [true, false])
@MainActor func readFailedCancelDuringRootCheckWins(lateLost: Bool) async throws {
    let fixture = FolderScanFixture(), host = ReadFailedHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: fixture.root.appendingPathComponent("待整理"), rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    try await gate.waitForCall(1)
    coordinator.cancel()
    let logAtCancel = host.log
    gate.answer(lost: lateLost)
    _ = try? await task.value
    #expect(coordinator.failure == nil && !readFailedIsScanFailure(session.imageStatus) && coordinator.snapshot == nil)
    #expect(!coordinator.isScanning && coordinator.retry() == nil)
    #expect(trace.events.filter { $0.hasSuffix("-1") && !$0.hasPrefix("begin") } == ["cancelled-1"])
    #expect(host.log == logAtCancel)
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedNewerOpenDuringRootCheckWins() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let first = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    try await gate.waitForCall(1)
    let second = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["b1.png", "b2.png"], at: 1)
    gate.answer(lost: false)
    _ = try? await first.value
    #expect(coordinator.failure == nil && coordinator.isReadingFolder && coordinator.generation == 2)
    #expect(coordinator.snapshot?.version.generation == 2 && coordinator.snapshot?.entries.count == 2)
    #expect(session.imageStatus == .readingFolder)
    await fixture.scanner.finish(1); try await second.value
    #expect(coordinator.completedImageCount == 2)
    #expect(host.log.suffix(2) == ["open-b1.png", "complete-2"])
    #expect(gate.calls.count == 1)
}

@MainActor private func readFailedCompletedSource()
    async throws -> (FolderScanFixture, FolderScanCoordinator, ViewerSession, ReadFailedHost, FolderFixTrace) {
    let fixture = FolderScanFixture(), host = ReadFailedHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let task = coordinator.begin(folder: fixture.root.appendingPathComponent("待整理"), rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png", "img3.png"])
    await fixture.scanner.finish(); try await task.value
    return (fixture, coordinator, session, host, trace)
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRefreshRootLostKeepsSourceWithoutFailure() async throws {
    let (fixture, coordinator, session, host, _) = try await readFailedCompletedSource()
    let gate = RootLossGate(fixed: true); gate.install(on: coordinator)
    let logBefore = host.log.count
    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.gone.error)
    _ = try? await refresh.value
    #expect(gate.calls.count == 1)
    // A Bool, so a RED never prints the ENOENT description (the receipt reads it as an environment failure).
    let failed = coordinator.failure != nil
    #expect(!failed)
    #expect(coordinator.sourceSnapshot?.entries.count == 3 && coordinator.sourceSnapshot?.isComplete == true)
    #expect(coordinator.completedImageCount == 3 && !readFailedIsScanFailure(session.imageStatus))
    #expect(Array(host.log[logBefore...]) == ["end"])
    let again = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(2); await fixture.scanner.finish(2); _ = try? await again.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRefreshRootReadablePublishesFailure() async throws {
    let (fixture, coordinator, session, host, _) = try await readFailedCompletedSource()
    let gate = RootLossGate(fixed: false); gate.install(on: coordinator)
    let logBefore = host.log.count
    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await refresh.value
    #expect(gate.calls.count == 1)
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    #expect(coordinator.sourceSnapshot?.entries.count == 3 && coordinator.completedImageCount == nil)
    // The fake files are absent, so the existing refresh path also clears the shown image.
    #expect(Array(host.log[logBefore...]) == ["clear", "end"])
    #expect(coordinator.retry() != nil)
    await fixture.scanner.waitForStart(2); await fixture.scanner.finish(2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRefreshEndDuringRootCheckIgnoresLateResult() async throws {
    let (fixture, coordinator, _, _, trace) = try await readFailedCompletedSource()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error)
    try await gate.waitForCall(1)
    coordinator.end()
    gate.answer(lost: false)
    _ = try? await refresh.value
    #expect(coordinator.failure == nil && coordinator.sourceSnapshot == nil)
    #expect(!trace.events.contains("failed-2") && trace.events.last == "cancelled-2")
}

// MARK: WI-3 — Retry, and Cancel during Retry, return to 「读取失败」.

/// Reaches F: a folder-entry read of `name` that fails with `kind` after one batch.
@MainActor private func readFailedState(_ kind: ReadFailedErrorKind = .io, name: String = "待整理",
    scene: (FolderScanFixture, FolderScanCoordinator, ViewerSession, ReadFailedHost, URL)? = nil, at index: Int = 0)
    async throws -> (FolderScanFixture, FolderScanCoordinator, ViewerSession, ReadFailedHost, ReadFailedProjection) {
    let (fixture, coordinator, session, host, _) = scene ?? readFailedScene(name)
    let task = coordinator.begin(folder: fixture.root.appendingPathComponent(name), rootID: fixture.id)
    await fixture.scanner.waitForStart(index)
    try await fixture.scanner.deliver(["img1.png"], at: index)
    await fixture.scanner.finish(index, failing: true, error: kind.error)
    _ = try? await task.value
    #expect(readFailedIsScanFailure(session.imageStatus))
    return (fixture, coordinator, session, host, readFailedProject(coordinator, session))
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRetrySucceedsShowsCompleteFolder() async throws {
    let (fixture, coordinator, session, host, _) = try await readFailedState()
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["img1.png", "img2.png"], at: 1)
    await fixture.scanner.finish(1); try await retry.value
    #expect(coordinator.failure == nil && coordinator.completedImageCount == 2 && coordinator.sourceSnapshot?.isComplete == true)
    #expect(!readFailedIsScanFailure(session.imageStatus) && session.imageStatus != .readingFolder)
    #expect(host.log.suffix(3) == ["remember", "open-img1.png", "complete-2"])
    #expect(await fixture.access.balance == [2, 2])
    // A cancel after the success does not bring the failure back.
    coordinator.cancel()
    #expect(coordinator.failure == nil)
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 2])
@MainActor func readFailedRetryFailsAgainReturnsToSameFailedState(batches: Int) async throws {
    let (fixture, coordinator, session, host, failed) = try await readFailedState()
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    if batches > 0 { try await fixture.scanner.deliver(["img1.png", "img2.png"], at: 1) }
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await retry.value
    #expect(readFailedProject(coordinator, session) == failed)
    #expect(host.log.filter { $0 == "end" }.count >= 2 && !host.log.contains { $0.hasPrefix("complete-") })
    #expect(await fixture.access.balance == [2, 2])
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRetryFailsWithNewErrorPublishesNewReason() async throws {
    let (fixture, coordinator, session, _, failed) = try await readFailedState(.denied)
    #expect(failed.failureReason == "Folder access denied")
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await retry.value
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    let now = readFailedProject(coordinator, session)
    #expect(now.conditions == failed.conditions && now.sourceNil && now.snapshotNil && !now.scanning)
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 2])
@MainActor func readFailedCancelDuringRetryRestoresFailedState(batches: Int) async throws {
    let (fixture, coordinator, session, host, failed) = try await readFailedState(.denied)
    #expect(!coordinator.isRetryingFailedRead)
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    if batches > 0 { try await fixture.scanner.deliver(["img1.png", "img2.png"], at: 1) }
    #expect(coordinator.isRetryingFailedRead)
    coordinator.cancel()
    #expect(!coordinator.isRetryingFailedRead)
    #expect(readFailedProject(coordinator, session) == failed)
    #expect(session.imageStatus == .folderScanFailed("Folder access denied", "待整理"))
    #expect(!coordinator.isScanning)
    await fixture.scanner.finish(1); _ = try? await retry.value
    #expect(readFailedProject(coordinator, session) == failed)
    let again = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(2)
    #expect(await fixture.scanner.startedCount == 3)
    #expect(!host.log.contains { $0.hasPrefix("complete-") || $0.hasPrefix("open-") })
    coordinator.cancel(); await fixture.scanner.finish(2); _ = try? await again.value
    #expect(await fixture.access.balance == [3, 3])
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedRepeatedRetryCancelIsStable() async throws {
    let (fixture, coordinator, session, host, failed) = try await readFailedState()
    var generation = coordinator.generation
    for cycle in 1...3 {
        let retry = try #require(coordinator.retry())
        await fixture.scanner.waitForStart(cycle)
        try await fixture.scanner.deliver(["img1.png"], at: cycle)
        coordinator.cancel()
        await fixture.scanner.finish(cycle); _ = try? await retry.value
        #expect(readFailedProject(coordinator, session) == failed, "cycle \(cycle)")
        #expect(coordinator.generation > generation, "cycle \(cycle)")
        generation = coordinator.generation
    }
    #expect(await fixture.access.balance == [4, 4])
    #expect(!host.log.contains { $0.hasPrefix("complete-") })
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedDoubleRetryThenCancelRestoresFailedState() async throws {
    let (fixture, coordinator, session, _, failed) = try await readFailedState()
    let first = try #require(coordinator.retry())
    let second = coordinator.retry()
    await fixture.scanner.waitForStart(1)
    coordinator.cancel()
    #expect(readFailedProject(coordinator, session) == failed)
    await fixture.scanner.finish(1); _ = try? await first.value
    if second != nil { await fixture.scanner.waitForStart(2); await fixture.scanner.finish(2); _ = try? await second?.value }
    #expect(readFailedProject(coordinator, session) == failed)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func readFailedLateEventsAfterCancelledRetryAreIgnored(lateFails: Bool) async throws {
    let (fixture, coordinator, session, host, failed) = try await readFailedState()
    let gate = RootLossGate(fixed: false); gate.install(on: coordinator)
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    coordinator.cancel()
    let logAtCancel = host.log
    try? await fixture.scanner.deliver(["late.png"], at: 1)
    await fixture.scanner.finish(1, failing: lateFails, error: ReadFailedErrorKind.io.error)
    _ = try? await retry.value
    #expect(readFailedProject(coordinator, session) == failed)
    #expect(gate.calls.isEmpty && host.log == logAtCancel)
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedCancelDuringRetryRootCheckRestoresFailedState() async throws {
    let (fixture, coordinator, session, host, failed) = try await readFailedState()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error)
    try await gate.waitForCall(1)
    coordinator.cancel()
    let logAtCancel = host.log
    gate.answer(lost: true)
    _ = try? await retry.value
    #expect(gate.calls.count == 1)
    #expect(readFailedProject(coordinator, session) == failed)
    #expect(host.log == logAtCancel)
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedEndDuringRetryClearsEverything() async throws {
    let (fixture, coordinator, session, _, _) = try await readFailedState()
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    coordinator.end()
    #expect(coordinator.failure == nil && coordinator.snapshot == nil && !coordinator.isScanning)
    #expect(coordinator.retry() == nil && session.imageStatus == .empty)
    await fixture.scanner.finish(1); _ = try? await retry.value
    #expect(await fixture.scanner.startedCount == 2 && coordinator.failure == nil)
}

enum ReadFailedRestoreRow: CaseIterable, Sendable { case newReason, successThenOpen, successThenFailedOpen }

@Test(.timeLimit(.minutes(2)), arguments: ReadFailedRestoreRow.allCases)
@MainActor func readFailedRestorePointTracksLatestFailureAndClears(row: ReadFailedRestoreRow) async throws {
    let (fixture, coordinator, session, _, _) = try await readFailedState(.denied)
    let first = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    switch row {
    case .newReason:
        await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error); _ = try? await first.value
        let latest = readFailedProject(coordinator, session)
        let second = try #require(coordinator.retry())
        await fixture.scanner.waitForStart(2)
        coordinator.cancel()
        #expect(readFailedProject(coordinator, session) == latest)
        #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
        await fixture.scanner.finish(2); _ = try? await second.value
    case .successThenOpen:
        await fixture.scanner.finish(1); try await first.value
        let open = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(2)
        coordinator.cancel()
        #expect(coordinator.failure == nil && !readFailedIsScanFailure(session.imageStatus))
        await fixture.scanner.finish(2); _ = try? await open.value
    case .successThenFailedOpen:
        await fixture.scanner.finish(1); try await first.value
        let open = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(2)
        await fixture.scanner.finish(2, failing: true, error: ReadFailedErrorKind.io.error); _ = try? await open.value
        let second = try #require(coordinator.retry())
        await fixture.scanner.waitForStart(3)
        coordinator.cancel()
        #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "B"))
        await fixture.scanner.finish(3); _ = try? await second.value
        let third = try #require(coordinator.retry())
        await fixture.scanner.waitForStart(4)
        #expect(await fixture.scanner.folder(at: 4) == fixture.root.appendingPathComponent("B"))
        coordinator.end(); await fixture.scanner.finish(4); _ = try? await third.value
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func readFailedSessionCancelFolderEntryReturnsReadFailedTarget() async throws {
    // Failure, nothing shown: Cancel Reading during Retry returns to 「读取失败」.
    do {
        let (fixture, coordinator, session, host, failed) = try await readFailedState(.denied)
        session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
        let retry = try #require(coordinator.retry())
        await fixture.scanner.waitForStart(1)
        #expect(session.cancelFolderEntry() == .readFailed)
        #expect(readFailedProject(coordinator, session) == failed)
        #expect(session.imageStatus == .folderScanFailed("Folder access denied", "待整理"))
        #expect(!host.log.contains { $0.hasPrefix("open-") })
        await fixture.scanner.finish(1); _ = try? await retry.value
    }
    // Failure with a shown image: the image wins.
    do {
        let (fixture, coordinator, session, _, _) = try await readFailedState()
        let shown = fixture.root.appendingPathComponent("待整理/img2.png")
        session.beginFolderEntry(shownImage: shown, hasCompleteGrid: false)
        let retry = try #require(coordinator.retry())
        await fixture.scanner.waitForStart(1)
        #expect(session.cancelFolderEntry() == .viewer(shown))
        await fixture.scanner.finish(1); _ = try? await retry.value
    }
    // No failure: the existing empty target.
    do {
        let (fixture, coordinator, session, _, folder) = readFailedScene()
        session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
        let open = coordinator.begin(folder: folder, rootID: fixture.id)
        await fixture.scanner.waitForStart()
        #expect(session.cancelFolderEntry() == .empty)
        await fixture.scanner.finish(); _ = try? await open.value
    }
}
