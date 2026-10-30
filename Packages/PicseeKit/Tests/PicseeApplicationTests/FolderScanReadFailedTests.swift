import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

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

@Test(arguments: [0, 1, 2, 3], ReadFailedErrorKind.allCases)
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

@Test @MainActor func readFailedAcquireFailureIsAReadFailureWithNoLease() async throws {
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

@Test(arguments: ["待整理", "A"])
@MainActor func readFailedStatusNamesTheFolderNotACount(name: String) async throws {
    let (fixture, coordinator, session, _, folder) = readFailedScene(name)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", name))
}

@Test @MainActor func readFailedFolderEntryRetryRescansWithoutSnapshot() async throws {
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

@Test(arguments: [0, 1, 3])
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
    /// Bounded, so a check that is never called fails the test instead of hanging it.
    func waitForCall(_ count: Int = 1) async {
        for _ in 0..<500 where calls.count < count { try? await Task.sleep(for: .milliseconds(10)) }
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

@Test(arguments: RootCheckOutcome.allCases, [0, 2])
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

@Test @MainActor func readFailedRootCheckPendingKeepsReadingState() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"]); try await fixture.scanner.deliver(["img2.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    await gate.waitForCall(1)
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

@Test @MainActor func readFailedRootLostHandsOffWithoutPublishingFailure() async throws {
    let fixture = FolderScanFixture(), host = ReadFailedHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: fixture.root.appendingPathComponent("待整理"), rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png", "img3.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.gone.error)
    await gate.waitForCall(1)
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

@Test @MainActor func readFailedRootReadablePublishesReadFailed() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.denied.error)
    await gate.waitForCall(1)
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

@Test(arguments: [0, 3])
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

@Test(arguments: ReadFailedEnding.allCases)
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

@Test(arguments: [true, false])
@MainActor func readFailedCancelDuringRootCheckWins(lateLost: Bool) async throws {
    let fixture = FolderScanFixture(), host = ReadFailedHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let gate = RootLossGate(); gate.install(on: coordinator)
    let task = coordinator.begin(folder: fixture.root.appendingPathComponent("待整理"), rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    await gate.waitForCall(1)
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

@Test @MainActor func readFailedNewerOpenDuringRootCheckWins() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let first = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    await gate.waitForCall(1)
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

@Test @MainActor func readFailedRefreshRootLostKeepsSourceWithoutFailure() async throws {
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

@Test @MainActor func readFailedRefreshRootReadablePublishesFailure() async throws {
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

@Test @MainActor func readFailedRefreshEndDuringRootCheckIgnoresLateResult() async throws {
    let (fixture, coordinator, _, _, trace) = try await readFailedCompletedSource()
    let gate = RootLossGate(); gate.install(on: coordinator)
    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true, error: ReadFailedErrorKind.io.error)
    await gate.waitForCall(1)
    coordinator.end()
    gate.answer(lost: false)
    _ = try? await refresh.value
    #expect(coordinator.failure == nil && coordinator.sourceSnapshot == nil)
    #expect(!trace.events.contains("failed-2") && trace.events.last == "cancelled-2")
}
