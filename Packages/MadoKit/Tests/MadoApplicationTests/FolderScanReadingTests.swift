import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class FolderReadingHost: FolderScanHost {
    var opens: [URL] = []
    var remembered: [(URL, AccessRootID)] = []
    var cleared = 0
    var onRemember: (() async throws -> Void)?
    var onOpen: (() -> Void)?
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url); onOpen?() }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws {
        remembered.append((folder, rootID)); try await onRemember?()
    }
    func clearFolderImageForNoMatches() { cleared += 1 }
}

@Test(.timeLimit(.minutes(2)), arguments: ["png", "none", "restore"])
@MainActor func folderReadingConditionChangeDuringRememberDoesNotReopenExcludedFirst(selection: String) async throws {
    let fixture = FolderScanFixture(), host = FolderReadingHost(), coordinator = fixture.coordinator
    coordinator.host = host
    host.onRemember = {
        coordinator.setConditions(.init(selectedExtensions: selection == "png" ? ["png"] : ["tiff"]))
        if selection == "restore" {
            coordinator.setConditions(.init(selectedExtensions: ["png"]))
            coordinator.setConditions(.init())
            #expect(coordinator.move(.previous))
        }
    }
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.png"])
    await fixture.scanner.finish(); try await task.value
    if selection == "restore" {
        #expect(host.opens.map(\.lastPathComponent) == ["b.png", "a.jpg"])
        #expect(coordinator.currentURL?.lastPathComponent == "a.jpg")
    } else if selection == "png" {
        #expect(host.opens.map(\.lastPathComponent) == ["b.png"])
        #expect(coordinator.currentURL?.lastPathComponent == "b.png")
        #expect(host.cleared == 0)
    } else {
        #expect(host.opens.isEmpty)
        #expect(coordinator.currentURL == nil && coordinator.hasNoMatches)
        #expect(host.cleared == 1)
    }
}

@Test(.timeLimit(.minutes(2)), arguments: ["jpg", "unchanged", "loop"])
@MainActor func folderReadingRetainedFirstDuringRememberOpensExactlyOnce(action: String) async throws {
    let fixture = FolderScanFixture(), host = FolderReadingHost(), coordinator = fixture.coordinator
    let session = ViewerSession()
    coordinator.host = host
    host.onRemember = {
        let jpg = FolderViewConditions(selectedExtensions: ["jpg"])
        coordinator.setConditions(jpg)
        if action == "unchanged" { coordinator.setConditions(jpg) }
        if action == "loop" {
            coordinator.setConditions(jpg)
            session.setFolderLoopEnabled(true)
        }
        #expect(host.opens.isEmpty)
    }
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.map(\.lastPathComponent) == ["a.jpg"])
    #expect(coordinator.currentURL?.lastPathComponent == "a.jpg")
    #expect(session.displayPreferences.loopThroughImages == (action == "loop"))
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func folderReadingUnchangedConditionsDuringRememberStillOpenFirst(loopMenu: Bool) async throws {
    let fixture = FolderScanFixture(), host = FolderReadingHost(), coordinator = fixture.coordinator
    let session = ViewerSession()
    coordinator.host = host
    host.onRemember = {
        // Reapplying unchanged conditions and changing the global preference must not suppress first presentation.
        coordinator.setConditions(coordinator.conditions)
        if loopMenu { session.setFolderLoopEnabled(true) }
        #expect(host.opens.isEmpty)
    }
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.map(\.lastPathComponent) == ["a.jpg"])
    #expect(coordinator.currentURL?.lastPathComponent == "a.jpg")
    #expect(session.displayPreferences.loopThroughImages == loopMenu)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderReadingCompletedSnapshotOpensNameFirstOnce() async throws {
    let fixture = FolderScanFixture(), host = FolderReadingHost(), session = ViewerSession()
    fixture.coordinator.host = host; session.folderScan = fixture.coordinator
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    #expect(session.imageStatus == .readingFolder)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver([])
    #expect(host.opens.isEmpty && fixture.coordinator.isReadingFolder)
    try await fixture.scanner.deliver(["img10.png", "img2.png"])
    #expect(host.opens.isEmpty && host.remembered.isEmpty)
    #expect(fixture.coordinator.isReadingFolder && fixture.coordinator.currentItemID == nil)
    try await fixture.scanner.deliver(["img1.png"])
    #expect(host.opens.isEmpty && fixture.coordinator.isReadingFolder)
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.map(\.lastPathComponent) == ["img1.png"])
    #expect(host.remembered.map(\.0) == [fixture.folder])
    #expect(host.remembered.map(\.1) == [fixture.id])
    #expect(host.remembered.count == 1 && !fixture.coordinator.isEmptyFolder)
    #expect(fixture.coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img1.png", "img2.png", "img10.png"])
    #expect(fixture.coordinator.currentItemID == .rootRelative(rootID: fixture.id, relativePath: "A/img1.png"))
    #expect(fixture.coordinator.currentURL == fixture.folder.appendingPathComponent("img1.png"))
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderReadingEmptyCompletionAndRootInput() async throws {
    for inputImage in [false, true] {
        let fixture = FolderScanFixture(), host = FolderReadingHost(), session = ViewerSession()
        session.folderScan = fixture.coordinator; fixture.coordinator.host = host
        let input = inputImage ? fixture.folder.appendingPathComponent("img2.png") : nil
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
        #expect(session.imageStatus == (inputImage ? .empty : .readingFolder))
        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver([])
        await fixture.scanner.finish(); try await task.value
        #expect(fixture.coordinator.isEmptyFolder)
        #expect(host.opens.isEmpty && host.remembered.isEmpty)
        #expect(session.imageStatus == .emptyFolder)
        #expect(await fixture.access.balance == [1, 1])
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderReadingFalseAuthorityBeforeAndAfterRemember() async throws {
    for falseAfterRemember in [false, true] {
        let fixture = FolderScanFixture(), host = FolderReadingHost()
        fixture.coordinator.host = host
        var allowed = falseAfterRemember
        host.onRemember = { allowed = false }
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, canPresent: { allowed })
        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["img2.png"])
        await fixture.scanner.finish(); try await task.value
        #expect(host.opens.isEmpty && !fixture.coordinator.isEmptyFolder)
        #expect(host.remembered.count == (falseAfterRemember ? 1 : 0))
        #expect(fixture.coordinator.failure == nil)
        #expect(await fixture.access.balance == [1, 1])
    }
    let fixture = FolderScanFixture(), host = FolderReadingHost()
    fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, canPresent: { false })
    await fixture.scanner.waitForStart(); await fixture.scanner.finish(); try await task.value
    #expect(!fixture.coordinator.isEmptyFolder && host.opens.isEmpty)
}

@Test(.timeLimit(.minutes(2)), arguments: ["cancel-remember", "replace-remember", "cancel-open"])
@MainActor func folderReadingReentrantEffectsRemainGenerationGuarded(action: String) async throws {
    let fixture = FolderScanFixture(), host = FolderReadingHost()
    fixture.coordinator.host = host
    var replacement: Task<Void, any Error>?
    if action == "cancel-open" { host.onOpen = { fixture.coordinator.cancel() } }
    else {
        host.onRemember = {
            if action == "cancel-remember" { fixture.coordinator.cancel() }
            else { replacement = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id) }
        }
    }
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img2.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.count == (action == "cancel-open" ? 1 : 0))
    #expect(await fixture.access.released.count == 1)
    if replacement != nil { await fixture.scanner.waitForStart(1) }
    #expect(host.remembered.count == 1 && !fixture.coordinator.isEmptyFolder)
    #expect(host.opens.count == (action == "cancel-open" ? 1 : 0))
    if let replacement {
        fixture.coordinator.cancel()
        await fixture.scanner.finish(1); try await replacement.value
        #expect(await fixture.access.balance == [2, 2])
    } else { #expect(await fixture.access.balance == [1, 1]) }
}

private struct FolderReadingOneBatchScanner: FolderScanning {
    func scan(in folder: URL, root: ItemIdentityRoot,
        options: FolderScanOptions, emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try await emit([FolderEntry(url: folder.appendingPathComponent("img2.png"), root: root)])
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderReadingRememberErrorEndsAndReleases() async {
    let access = FolderScanCountingLeases(root: URL(fileURLWithPath: "/folder-reading"))
    let coordinator = FolderScanCoordinator(access: access, scanner: FolderReadingOneBatchScanner()), host = FolderReadingHost()
    coordinator.host = host
    host.onRemember = { throw FolderScanTestError.expected }
    let task = coordinator.begin(folder: URL(fileURLWithPath: "/folder-reading/A"), rootID: AccessRootID())
    await #expect(throws: FolderScanTestError.expected) { try await task.value }
    #expect(coordinator.failure is FolderScanTestError)
    #expect(!coordinator.isReadingFolder)
    #expect(host.opens.isEmpty && !coordinator.isEmptyFolder && host.remembered.count == 1)
    #expect(await access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderReadingCancelRestoresPriorLoader() async throws {
    for showing in [false, true] {
        let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: FolderNavigationHost())
        session.host = host; session.folderScan = fixture.coordinator
        let imageHost = LoadHost(), pipeline = LoadPipeline(), imageAccess = LoadLeases()
        session.imageLoader.host = imageHost
        if showing {
            let file = URL(fileURLWithPath: "/prior.png")
            session.openImage(file, maximumPixelSize: 512) {
                try await AccessImageSource.open(.fileGrant(file), access: imageAccess, pipeline: pipeline)
            }
            await session.imageLoader.loadTask?.value
        }
        let before = session.imageStatus, generation = session.imageLoader.generation
        let presented = session.imageLoader.presented?.key
        #expect(before == (showing ? .showing : .empty))
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
        #expect(session.imageStatus == .readingFolder)
        #expect(!session.imageCommandsAvailable)
        await fixture.scanner.waitForStart()
        session.cancelFolderReading()
        #expect(session.imageStatus == before)
        #expect(session.imageLoader.generation == generation)
        #expect(session.imageLoader.presented?.key == presented)
        try await fixture.scanner.deliver(["late.png"])
        await fixture.scanner.finish(); try await task.value
        #expect(session.imageStatus == before)
        #expect(await fixture.access.balance == [1, 1])
        session.closeImage()
    }
}

private actor FolderReadingOriginBarrier {
    private var ending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { ending = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if ending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { ending?.resume(); ending = nil }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func folderReadingCancelledOriginCannotPresent(hasBatch: Bool) async throws {
    let fixture = FolderScanFixture(), host = FolderReadingHost(), originBarrier = FolderReadingOriginBarrier()
    fixture.coordinator.host = host
    let origin = Task { await originBarrier.hold() }
    await originBarrier.waitForStart()
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, canPresent: { !origin.isCancelled })
    await fixture.scanner.waitForStart()
    origin.cancel()
    if hasBatch { try await fixture.scanner.deliver(["img2.png"]) }
    await fixture.scanner.finish(); try await task.value
    #expect(origin.isCancelled)
    #expect(host.opens.isEmpty && host.remembered.isEmpty && !fixture.coordinator.isEmptyFolder)
    #expect(await fixture.access.balance == [1, 1])
    await originBarrier.finish(); await origin.value
}
