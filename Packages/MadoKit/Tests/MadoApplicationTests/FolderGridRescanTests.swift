import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func p204R4RetryAfterNavigationKeepsCurrentImageAndSnapshotOrder() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let coordinator = fixture.coordinator, session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let img1 = fixture.folder.appendingPathComponent("img1.png"), img2 = fixture.folder.appendingPathComponent("img2.png")
    let img3 = fixture.folder.appendingPathComponent("img3.png")
    let first = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: img1)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img10.png", "img1.png", "img2.png"])
    await fixture.scanner.finish(failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await first.value }
    #expect(coordinator.move(.next, currentURL: img1))
    #expect(host.visible == img2)
    let retry = try #require(coordinator.retry())
    #expect(coordinator.currentURL == img2 && coordinator.inputURL == img2)
    #expect(!coordinator.isReadingFolder)
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["img10.png", "img1.png", "img3.png", "img2.png"], at: 1)
    await fixture.scanner.finish(1); try await retry.value
    #expect(host.opens.map(\.0) == [img2])
    #expect(coordinator.canMove(.next, currentURL: img2) == true)
    #expect(coordinator.move(.next, currentURL: img2))
    #expect(host.visible == img3)
    #expect(coordinator.move(.previous, currentURL: img3))
    #expect(host.opens.map(\.0) == [img2, img3, img2])
    #expect(host.navigation.isEmpty)
    #expect(await fixture.access.balance == [2, 2])
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204R4GridProjectionKeepsCompleteGridUntilNewerCompleteSnapshot() {
    let rootID = AccessRootID(rawValue: UUID())
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-rescan")
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let a = FolderEntry(url: folder.appendingPathComponent("a.png"), root: root)
    let b = FolderEntry(url: folder.appendingPathComponent("b.png"), root: root)
    let c = FolderEntry(url: folder.appendingPathComponent("sub/c.png"), root: root)
    func snapshot(_ generation: UInt64, _ entries: [FolderEntry], complete: Bool) -> FolderSnapshot {
        FolderSnapshot(version: SnapshotVersion(rootID: rootID, folder: folder, generation: generation),
            entries: entries, isComplete: complete)
    }
    let reading = FolderGridProjection()
    #expect(reading.apply(snapshot(0, [], complete: false)))
    #expect(reading.apply(snapshot(1, [a], complete: false)))
    #expect(reading.entry(for: a.itemID) != nil)

    let grid = FolderGridProjection()
    let shown = snapshot(1, [a, b], complete: true)
    #expect(grid.apply(shown))
    grid.select(b.itemID)
    #expect(!grid.apply(snapshot(2, [], complete: false)))
    #expect(!grid.apply(snapshot(2, [a], complete: false)))
    #expect(grid.snapshot == shown)
    #expect(grid.entry(for: b.itemID)?.url == b.url)
    #expect(grid.selectedItemID == b.itemID)
    #expect(grid.apply(snapshot(2, [a, b, c], complete: true)))
    #expect(grid.entry(for: c.itemID)?.url == c.url)
    #expect(grid.selectedItemID == b.itemID)
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204R4GridRecursiveToggleReadsCancelsAndFails() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let coordinator = fixture.coordinator, session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let open = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png", "b.png"])
    await fixture.scanner.finish(); try await open.value
    let flat = try #require(coordinator.sourceSnapshot)
    session.enterFolderGrid(items: flat.navigationEntries.map(\.itemID), sourceVersion: .init(1))
    session.completeFolderEntry()

    let toggled = try #require(session.setFolderRecursiveEnabled(true))
    await fixture.scanner.waitForStart(1)
    #expect(await fixture.scanner.options(at: 1).recursive)
    #expect(coordinator.isReadingFolder && session.imageStatus == .readingFolder)
    #expect(session.cancelFolderEntry() == .grid)
    #expect(session.mode == .browsing && !coordinator.isReadingFolder)
    #expect(coordinator.sourceSnapshot == flat && !coordinator.recursiveEnabled)
    await fixture.scanner.finish(1); try await toggled.value
    #expect(coordinator.sourceSnapshot == flat)

    let failing = try #require(session.setFolderRecursiveEnabled(true))
    await fixture.scanner.waitForStart(2)
    try await fixture.scanner.deliver(["a.png"], at: 2)
    await fixture.scanner.finish(2, failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await failing.value }
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "A"))
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(3)
    #expect(coordinator.isReadingFolder && session.imageStatus == .readingFolder)
    try await fixture.scanner.deliver(["a.png", "b.png", "sub/c.png"], at: 3)
    await fixture.scanner.finish(3); try await retry.value
    #expect(coordinator.snapshot?.isComplete == true && coordinator.snapshot?.entries.count == 3)
    #expect(coordinator.recursiveEnabled && session.imageStatus != .readingFolder)
}

@Test(.timeLimit(.minutes(2))) @MainActor func p204R4GridToggleWithoutScanLeavesNoRestorePoint() {
    let fixture = FolderScanFixture(), session = ViewerSession(host: FolderNavigationHost())
    session.folderScan = fixture.coordinator
    session.enterFolderGrid(items: [], sourceVersion: .init(0))
    #expect(session.setFolderRecursiveEnabled(true) == nil)
    #expect(session.folderRecursiveEnabled)
    #expect(session.cancelFolderEntry() == nil)
}
