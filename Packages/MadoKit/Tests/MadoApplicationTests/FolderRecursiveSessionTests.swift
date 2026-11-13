import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func recursiveToggleReplacesGenerationAndDiscardsOldBatch() async throws {
    let fixture = FolderScanFixture()
    let old = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    #expect(await fixture.scanner.options(at: 0).recursive == false)
    let replacement = try #require(fixture.coordinator.setRecursiveEnabled(true))
    await fixture.scanner.waitForStart(1)
    #expect(fixture.coordinator.recursiveEnabled)
    #expect(await fixture.scanner.options(at: 1).recursive)
    try await fixture.scanner.deliver(["old.png"], at: 0)
    #expect(fixture.coordinator.snapshot?.entries.isEmpty == true)
    try await fixture.scanner.deliver(["sub/new.png"], at: 1)
    #expect(fixture.coordinator.snapshot?.entries.map(\.relativePath) == ["A/sub/new.png"])
    await fixture.scanner.finish(0)
    await fixture.scanner.finish(1)
    try await old.value
    try await replacement.value
    #expect(await fixture.access.balance == [2, 2])
}

private struct PartialFailureScanner: FolderScanning {
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try await emit([FolderEntry(url: folder.appendingPathComponent("one.png"), root: root)])
        throw FolderScanLimitError.entryLimit(limit: 1, admittedImages: 1)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderScanFailureKeepsPartialCountAndRecoverableState() async {
    let fixture = FolderScanFixture()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: PartialFailureScanner())
    let session = ViewerSession(host: nil)
    session.folderScan = coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    _ = try? await task.value
    // #238: a folder-entry failure keeps no partial source (24F-A shows no partial list or count).
    #expect(coordinator.sourceSnapshot == nil && coordinator.snapshot == nil)
    #expect(session.imageStatus == .folderScanFailed("Scan limit reached", "A"))
    #expect(await fixture.access.balance == [1, 1])
}

@MainActor private final class RecursiveSelectionHost: FolderScanHost, ViewerSessionNavigationHost, ViewerImageHost {
    var opened: [URL] = []
    var cleared = 0
    var paintedURL: URL?
    var nativeFileURL: URL?
    var retryAvailable = false
    var hasImage: Bool { paintedURL != nil }
    var canNavigate: Bool { nativeFileURL != nil }
    weak var session: ViewerSession?
    func openFolderImage(_ url: URL, rootID: AccessRootID) {
        opened.append(url); paintedURL = url; nativeFileURL = url; retryAvailable = true
    }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { }
    func clearFolderImageForNoMatches() {
        cleared += 1; paintedURL = nil; nativeFileURL = nil; retryAvailable = false; session?.closeImage()
    }
    func beginImageOpening() { }
    func installImage(_ image: DecodedImage, fileURL: URL) {
        paintedURL = fileURL; nativeFileURL = fileURL; retryAvailable = true
    }
    func imageLoadFailed(_ error: any Error) { }
    func navigate(_ direction: NavigationDirection) { }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func requestOpen() { }
    func applyFocus(_ focus: FocusContext) { }
    func showInspector(_ visible: Bool) { }
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204FixR2RapidOffOnOffClearsSettledNestedPresentation() async throws {
    let fixture = FolderScanFixture(), host = RecursiveSelectionHost()
    let session = ViewerSession(host: host), pipeline = LoadPipeline(), leases = LoadLeases()
    host.session = session
    session.folderScan = fixture.coordinator
    session.imageLoader.host = host
    fixture.coordinator.host = host
    _ = fixture.coordinator.setRecursiveEnabled(true)
    let nested = fixture.folder.appendingPathComponent("sub/nested.png")
    let initial = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: nested)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["sub/nested.png"])
    await fixture.scanner.finish(); try await initial.value
    session.openImage(nested, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(nested), access: leases, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .settled && host.paintedURL == nested)
    let firstOff = try #require(fixture.coordinator.setRecursiveEnabled(false))
    await fixture.scanner.waitForStart(1)
    let on = try #require(fixture.coordinator.setRecursiveEnabled(true))
    await fixture.scanner.waitForStart(2)
    let finalOff = try #require(fixture.coordinator.setRecursiveEnabled(false))
    await fixture.scanner.waitForStart(3)
    #expect(host.paintedURL == nested && host.cleared == 0)
    await fixture.scanner.finish(1); await fixture.scanner.finish(2)
    await fixture.scanner.finish(3)
    try await firstOff.value; try await on.value; try await finalOff.value
    #expect(fixture.coordinator.snapshot?.isComplete == true)
    #expect(fixture.coordinator.snapshot?.entries.isEmpty == true)
    #expect(host.cleared == 1 && fixture.coordinator.isEmptyFolder)
    #expect(host.paintedURL == nil && host.nativeFileURL == nil && !host.retryAvailable)
    #expect(session.imageLoader.fileURL == nil && session.imageStatus == .emptyFolder)
    #expect(!session.isEnabled(.next) && !session.isEnabled(.previous))
    #expect(await fixture.access.balance == [4, 4])
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204FixR2FailedOffRetryClearsSettledNestedPresentation() async throws {
    let fixture = FolderScanFixture(), host = RecursiveSelectionHost()
    let session = ViewerSession(host: host), pipeline = LoadPipeline(), leases = LoadLeases()
    host.session = session
    session.folderScan = fixture.coordinator
    session.imageLoader.host = host
    fixture.coordinator.host = host
    _ = fixture.coordinator.setRecursiveEnabled(true)
    let nested = fixture.folder.appendingPathComponent("sub/nested.png")
    let initial = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: nested)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["sub/nested.png"])
    await fixture.scanner.finish(); try await initial.value
    session.openImage(nested, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(nested), access: leases, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .settled && host.paintedURL == nested)
    let off = try #require(fixture.coordinator.setRecursiveEnabled(false))
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1, failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await off.value }
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "A"))
    #expect(host.paintedURL == nested && host.cleared == 0)
    let retry = try #require(fixture.coordinator.retry())
    await fixture.scanner.waitForStart(2)
    await fixture.scanner.finish(2); try await retry.value
    #expect(fixture.coordinator.snapshot?.entries.isEmpty == true)
    #expect(host.cleared == 1 && fixture.coordinator.isEmptyFolder)
    #expect(host.paintedURL == nil && host.nativeFileURL == nil && !host.retryAvailable)
    #expect(session.imageLoader.fileURL == nil && session.imageStatus == .emptyFolder)
    #expect(!session.isEnabled(.next) && !session.isEnabled(.previous))
    #expect(await fixture.access.balance == [3, 3])
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204FixR2CancelledOffKeepsSettledImageAndReplacementPresentsTopLevel() async throws {
    let fixture = FolderScanFixture(), host = RecursiveSelectionHost()
    let session = ViewerSession(host: host), pipeline = LoadPipeline(), leases = LoadLeases()
    host.session = session
    session.folderScan = fixture.coordinator
    session.imageLoader.host = host
    fixture.coordinator.host = host
    _ = fixture.coordinator.setRecursiveEnabled(true)
    let nested = fixture.folder.appendingPathComponent("sub/nested.png")
    let top = fixture.folder.appendingPathComponent("top.png")
    let initial = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: nested)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["sub/nested.png", "top.png"])
    await fixture.scanner.finish(); try await initial.value
    session.openImage(nested, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(nested), access: leases, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    let cancelled = try #require(fixture.coordinator.setRecursiveEnabled(false))
    await fixture.scanner.waitForStart(1)
    fixture.coordinator.cancel()
    await fixture.scanner.finish(1); try await cancelled.value
    #expect(host.cleared == 0 && host.paintedURL == nested)
    #expect(session.imageLoader.phase == .settled && session.imageLoader.fileURL == nested)
    let replacement = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart(2)
    try await fixture.scanner.deliver(["top.png"], at: 2)
    await fixture.scanner.finish(2); try await replacement.value
    #expect(host.opened.last == top && host.paintedURL == top)
    #expect(host.cleared == 0 && fixture.coordinator.currentURL == top)
    #expect(await fixture.access.balance == [3, 3])
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204FixEmptyFlatToggleClearsExcludedNestedImage() async throws {
    let fixture = FolderScanFixture(), host = RecursiveSelectionHost()
    let session = ViewerSession(host: nil)
    host.session = session
    session.folderScan = fixture.coordinator
    fixture.coordinator.host = host
    _ = fixture.coordinator.setRecursiveEnabled(true)
    let nested = fixture.folder.appendingPathComponent("sub/nested.png")
    let first = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: nested)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["sub/nested.png"])
    await fixture.scanner.finish(); try await first.value
    session.openImage(nested, maximumPixelSize: 1) { throw CancellationError() }
    #expect(session.imageLoader.fileURL == nested)
    let second = try #require(fixture.coordinator.setRecursiveEnabled(false))
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1); try await second.value
    #expect(fixture.coordinator.snapshot?.entries.isEmpty == true)
    #expect(fixture.coordinator.currentURL == nil)
    #expect(host.cleared == 1)
    #expect(session.imageLoader.fileURL == nil)
    #expect(session.imageStatus == .emptyFolder)
    #expect(fixture.coordinator.canMove(.next, currentURL: nested) == false)
    #expect(fixture.coordinator.canMove(.previous, currentURL: nested) == false)
}

@Test(.timeLimit(.minutes(2))) @MainActor func recursiveToggleOffRemovesNestedSelectionAndKeepsConditions() async throws {
    let fixture = FolderScanFixture(), host = RecursiveSelectionHost()
    fixture.coordinator.host = host
    _ = fixture.coordinator.setRecursiveEnabled(true)
    let nested = fixture.folder.appendingPathComponent("sub/nested.png")
    let first = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: nested)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["top.jpg", "sub/nested.png"])
    await fixture.scanner.finish(); try await first.value
    #expect(fixture.coordinator.currentURL == nested)
    fixture.coordinator.setConditions(.init(sort: .name, direction: .descending))
    let second = try #require(fixture.coordinator.setRecursiveEnabled(false))
    #expect(fixture.coordinator.currentURL == nil)
    await fixture.scanner.waitForStart(1)
    #expect(await fixture.scanner.options(at: 1).recursive == false)
    try await fixture.scanner.deliver(["top.jpg"], at: 1)
    await fixture.scanner.finish(1); try await second.value
    #expect(fixture.coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["top.jpg"])
    #expect(fixture.coordinator.currentURL?.lastPathComponent == "top.jpg")
    #expect(host.opened.map(\.lastPathComponent) == ["top.jpg"])
    #expect(fixture.coordinator.conditions.direction == .descending)
    #expect(await fixture.access.balance == [2, 2])
}

@Test(.timeLimit(.minutes(2))) @MainActor func recursiveSessionFacadeTogglesAndRetryStartsFreshLease() async throws {
    let fixture = FolderScanFixture(), session = ViewerSession(host: nil)
    session.folderScan = fixture.coordinator
    #expect(!session.folderRecursiveEnabled)
    let first = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    session.setFolderRecursiveEnabled(true)
    await fixture.scanner.waitForStart(1)
    #expect(session.folderRecursiveEnabled)
    await fixture.scanner.finish(0)
    await fixture.scanner.finish(1, failing: true)
    try await first.value
    try await waitUntil { fixture.coordinator.failure != nil }
    #expect(fixture.coordinator.failure != nil)
    session.retryFolderScan()
    await fixture.scanner.waitForStart(2)
    #expect(await fixture.scanner.options(at: 2).recursive)
    await fixture.scanner.finish(2)
    try await waitUntil { fixture.coordinator.sourceSnapshot?.isComplete == true }
    #expect(fixture.coordinator.sourceSnapshot?.isComplete == true)
    #expect(await fixture.access.balance == [3, 3])
}

private struct PermissionFailureScanner: FolderScanning {
    let error: any Error
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws { throw error }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderScanPermissionFailureIsRecoverableAndNoCountInvented() async {
    let fixture = FolderScanFixture()
    let coordinator = FolderScanCoordinator(access: fixture.access,
        scanner: PermissionFailureScanner(error: POSIXError(.EPERM)))
    let session = ViewerSession(host: nil); session.folderScan = coordinator
    _ = try? await coordinator.begin(folder: fixture.folder, rootID: fixture.id).value
    #expect(session.imageStatus == .folderScanFailed("Folder access denied", "A"))
    #expect(coordinator.completedImageCount == nil)
    // #238: a folder-entry failure keeps no partial source.
    #expect(coordinator.sourceSnapshot == nil)
    #expect(await fixture.access.balance == [1, 1])
}

private actor RootFailureLease: AccessLeasing {
    var requests = 0
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        requests += 1
        throw FileAccessError.invalidFolder
    }
    func release(_ lease: AccessLease) { }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderAccessFailureBeforeSnapshotShowsZeroAndCanRetry() async {
    let fixture = FolderScanFixture(), access = RootFailureLease(), session = ViewerSession(host: nil)
    #expect(session.folderRecursiveEnabled == false)
    let coordinator = FolderScanCoordinator(access: access, scanner: fixture.scanner)
    session.folderScan = coordinator
    #expect(session.folderRecursiveEnabled == false)
    _ = try? await coordinator.begin(folder: fixture.folder, rootID: fixture.id).value
    #expect(session.imageStatus == .folderScanFailed("Folder access denied", "A"))
    #expect(coordinator.sourceSnapshot == nil)
    _ = try? await coordinator.retry()?.value
    #expect(await access.requests == 2)
}
