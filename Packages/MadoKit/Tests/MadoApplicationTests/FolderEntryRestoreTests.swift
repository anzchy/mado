import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func cancelReadingTargetsFolderNavigatedViewerImageOnce() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let a = fixture.folder.appendingPathComponent("a.png"), b = fixture.folder.appendingPathComponent("b.png")
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: a)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png", "b.png", "c.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(fixture.coordinator.move(.next))
    #expect(host.visible == b)
    #expect(session.cancelFolderEntry() == nil)

    session.beginFolderEntry(shownImage: b, hasCompleteGrid: false)
    session.enterFolderGrid(items: [], sourceVersion: .init(0))
    let reading = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
    #expect(session.cancelFolderEntry() == .viewer(b))
    #expect(session.mode == .viewing)
    #expect(!fixture.coordinator.isReadingFolder)
    #expect(session.cancelFolderEntry() == nil)
    await fixture.scanner.finish(1); try await reading.value

    session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
    session.completeFolderEntry()
    #expect(session.cancelFolderEntry() == nil)
    session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
    #expect(session.cancelFolderEntry() == .empty)
}

@MainActor private final class RestoreHost: FolderScanHost, ViewerSessionHost {
    var hasImage = true
    var opens: [URL] = []
    var presented: [ItemID] = []
    var gridReturns = 0
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws {}
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { presented.append(id) }
    func returnToGrid() { gridReturns += 1 }
}

@MainActor private func scannedSession(input: String? = nil, finish: Bool = true) async throws
    -> (FolderScanFixture, RestoreHost, ViewerSession, Task<Void, any Error>) {
    let fixture = FolderScanFixture(), host = RestoreHost(), session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: input.map { fixture.folder.appendingPathComponent($0) })
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png", "b.jpg", "c.png"])
    if finish { await fixture.scanner.finish(); try await task.value }
    return (fixture, host, session, task)
}

@Test(.timeLimit(.minutes(2))) @MainActor func cancelReadingRestoresPreviewAndFolderSource() async throws {
    let router = CommandRouter()

    // (a) Previewing b from a grid → Cancel shows b again; Esc still returns to the origin grid.
    do {
        let (fixture, host, session, _) = try await scannedSession()
        let entries = try #require(fixture.coordinator.snapshot?.navigationEntries)
        let ids = entries.map(\.itemID)
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[2])
        session.select(ids[0])
        #expect(router.route(.preview, from: .key, to: session))
        #expect(router.route(.next, from: .key, to: session))
        #expect(session.previewSet?.currentItemID == ids[1])
        let captured = fixture.coordinator.snapshot
        session.beginFolderEntry(shownImage: entries[1].url, hasCompleteGrid: true)
        session.enterFolderGrid(items: [], sourceVersion: .init(0))
        let reading = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(1)
        #expect(session.cancelFolderEntry() == .viewer(entries[1].url))
        #expect(session.mode == .viewing)
        #expect(session.previewSet?.currentItemID == ids[1])
        #expect(fixture.coordinator.snapshot == captured)
        try await fixture.scanner.deliver(["z.png"], at: 1)
        await fixture.scanner.finish(1); try await reading.value
        #expect(fixture.coordinator.snapshot == captured, "a cancelled scan's late batch must not repaint")
        #expect(!host.opens.contains { $0.lastPathComponent == "z.png" })
        #expect(router.route(.escape, from: .key, to: session))
        #expect(host.gridReturns == 1)
        #expect(session.selection.selectedItemIDs == [ids[1]])
        // #492 / owner #345: cancelling folder entry preserves the last-viewed return destination.
        #expect(session.currentItemID == ids[1])
        #expect(session.scrollAnchor == ids[1])
        #expect(router.route(.preview, from: .key, to: session))
        #expect(host.presented.last == ids[1])
    }

    // (b) Grid → Cancel keeps the folder source, conditions, loop and navigation identity; no rescan.
    do {
        let (fixture, host, session, _) = try await scannedSession()
        let coordinator = fixture.coordinator
        let entries = try #require(coordinator.snapshot?.navigationEntries)
        let ids = entries.map(\.itemID)
        session.setFolderLoopEnabled(true)
        session.setFolderConditions(.init(selectedExtensions: ["png", "jpg"]))
        let captured = coordinator.snapshot, conditions = coordinator.conditions
        let current = coordinator.currentItemID, currentURL = coordinator.currentURL
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
        session.select(ids[2])
        session.beginFolderEntry(shownImage: nil, hasCompleteGrid: true)
        session.enterFolderGrid(items: [], sourceVersion: .init(0))
        let reading = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(1)
        let generation = coordinator.generation
        #expect(session.cancelFolderEntry() == .grid)
        #expect(!coordinator.isReadingFolder)
        #expect(coordinator.generation == generation)
        #expect(session.hasFolderSource)
        #expect(coordinator.snapshot == captured)
        #expect(coordinator.conditions == conditions && session.displayPreferences.loopThroughImages)
        #expect(coordinator.currentItemID == current && coordinator.currentURL == currentURL)
        #expect(session.mode == .browsing)
        #expect(session.selection.selectedItemIDs == [ids[2]])
        let opens = host.opens.count
        session.setFolderConditions(.init(selectedExtensions: ["png"]))
        #expect(coordinator.snapshot?.navigationEntries.map { $0.url.lastPathComponent } == ["a.png", "c.png"])
        #expect(host.opens.count == opens, "a filter change over the restored grid must not open an image")
        #expect(router.route(.preview, from: .key, to: session))
        #expect(host.presented == [ids[2]])
        await fixture.scanner.finish(1); try await reading.value
    }

    // (c) Folder-navigated image → Cancel keeps arrow navigation.
    do {
        let (fixture, host, session, _) = try await scannedSession(input: "a.png")
        let b = fixture.folder.appendingPathComponent("b.jpg")
        #expect(fixture.coordinator.move(.next))
        session.beginFolderEntry(shownImage: b, hasCompleteGrid: false)
        session.enterFolderGrid(items: [], sourceVersion: .init(0))
        let reading = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(1)
        #expect(session.cancelFolderEntry() == .viewer(b))
        #expect(fixture.coordinator.canMove(.previous, currentURL: b) == true)
        #expect(fixture.coordinator.move(.previous, currentURL: b))
        #expect(host.opens.last?.lastPathComponent == "a.png")
        await fixture.scanner.finish(1); try await reading.value
    }

    // (d) An incomplete source is not restored.
    do {
        let (fixture, _, session, task) = try await scannedSession(input: "a.png", finish: false)
        let a = fixture.folder.appendingPathComponent("a.png")
        session.beginFolderEntry(shownImage: a, hasCompleteGrid: false)
        #expect(session.cancelFolderEntry() == .viewer(a))
        #expect(!session.hasFolderSource)
        await fixture.scanner.finish(); try await task.value
    }
}
