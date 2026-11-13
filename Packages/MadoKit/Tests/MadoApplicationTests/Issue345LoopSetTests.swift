import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class Issue345Host: ViewerSessionHost, ViewerInputHost {
    var hasImage = true
    var presented: [ItemID] = []
    var opened: [URL] = []
    var present: ((ItemID) -> Void)?
    var open: ((URL) -> Void)?
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { presented.append(id); present?(id) }
    func returnToGrid() {}
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) { opened.append(url); open?(url) }
    func showInputNotice(_ notice: ViewerInputNotice) {}
    func promptForInputFolder(_ folder: URL) {}
}

@MainActor private func issue345Route(_ command: CommandID, _ session: ViewerSession) {
    _ = CommandRouter().route(command, from: .key, to: session)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue345PreviewLiveToggleStopsWrapsAndPersistsOnReturn() {
    let ids = sessionItems(3), store = InMemoryDisplayPreferencesStore(), host = Issue345Host()
    let session = ViewerSession(preferencesStore: store, host: host)
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    session.select(ids[0]); issue345Route(.preview, session)
    func step(_ command: CommandID, _ index: Int) {
        issue345Route(command, session); #expect(session.currentItemID == ids[index])
    }
    step(.previous, 0)
    session.setFolderLoopEnabled(true); step(.previous, 2); step(.next, 0)
    session.setFolderLoopEnabled(false); step(.previous, 0); step(.next, 1); step(.next, 2); step(.next, 2)
    session.setFolderLoopEnabled(true); step(.next, 0)
    #expect(host.presented == [ids[0], ids[2], ids[0], ids[1], ids[2], ids[0]])
    issue345Route(.escape, session)
    #expect(store.value.loopThroughImages)
    issue345Route(.preview, session); step(.previous, 2)
}

@Test(.timeLimit(.minutes(2)), arguments: [2, 3, 5], [false, true]) @MainActor
func issue345GridOrderFilterAndSelectionCycles(count: Int, descending: Bool) async throws {
    let fixture = FolderScanFixture(), host = Issue345Host(), store = InMemoryDisplayPreferencesStore()
    let session = ViewerSession(preferencesStore: store, host: host)
    session.folderScan = fixture.coordinator
    let scan = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver((1...count).reversed().map { "img\($0).png" } + ["excluded.jpg"])
    await fixture.scanner.finish(); try await scan.value
    session.setFolderConditions(.init(sort: .name, direction: descending ? .descending : .ascending,
                                     selectedExtensions: ["png"]))
    let entries = try #require(fixture.coordinator.snapshot?.navigationEntries)
    let names = (1...count).map { "img\($0).png" }
    #expect(entries.map(\.url.lastPathComponent) == (descending ? Array(names.reversed()) : names))
    let ids = entries.map(\.itemID)
    for multi in [false, true] {
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
        session.select(ids[0])
        if multi { session.select(ids[count - 1], modifier: .command) }
        let order = multi ? [ids[0], ids[count - 1]] : ids
        let start = multi ? order.count - 1 : 0
        session.setFolderLoopEnabled(true); issue345Route(.preview, session)
        var index = start
        for direction in [CommandID.next, .previous] {
            for _ in 0..<(2 * order.count) {
                index = (index + (direction == .next ? 1 : order.count - 1)) % order.count
                issue345Route(direction, session)
                #expect(session.currentItemID == order[index])
                #expect(session.previewSet?.itemIDs == order)
            }
            #expect(session.currentItemID == order[start])
        }
        // A later grid update cannot grow or reorder the frozen set.
        session.updateItems(ids.reversed() + sessionItems(1), sourceVersion: .init(2))
        #expect(session.previewSet?.itemIDs == order)
        issue345Route(.escape, session)
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 1], [false, true]) @MainActor
func issue345EmptyAndSingletonNeverReload(count: Int, loop: Bool) {
    let ids = sessionItems(count), host = Issue345Host(), session = ViewerSession(host: host)
    session.setFolderLoopEnabled(loop)
    session.beginBrowsing(items: ids, sourceVersion: .init(0), scrollAnchor: nil)
    if let id = ids.first { session.select(id) }
    issue345Route(.preview, session)
    let shown = host.presented
    for _ in 0..<3 { issue345Route(.next, session); issue345Route(.previous, session) }
    #expect(session.currentItemID == ids.first)
    #expect(host.presented == shown)
    let files = (0..<count).map { URL(fileURLWithPath: "/single/\($0).png") }
    session.filePreviewSet = FilePreviewSet(files: files)
    for _ in 0..<3 { issue345Route(.next, session); issue345Route(.previous, session) }
    #expect(session.filePreviewSet?.current == files.first)
    #expect(host.opened.isEmpty)
    #expect(!session.isEnabled(.next) && !session.isEnabled(.previous))
}

@Test(.timeLimit(.minutes(2)), arguments: [2, 3, 5]) @MainActor func issue345FinderLiveToggleAndCycles(count: Int) {
    let files = (0..<count).map { URL(fileURLWithPath: "/finder/\($0).png") }
    let store = InMemoryDisplayPreferencesStore(), host = Issue345Host()
    let session = ViewerSession(preferencesStore: store, host: host)
    let other = ViewerSession(preferencesStore: store)
    session.filePreviewSet = FilePreviewSet(files: files)
    issue345Route(.previous, session)
    #expect(session.filePreviewSet?.current == files[0]); #expect(host.opened.isEmpty)
    other.setFolderLoopEnabled(true)
    #expect(session.isEnabled(.previous))
    issue345Route(.previous, session); #expect(session.filePreviewSet?.current == files.last)
    issue345Route(.next, session); #expect(session.filePreviewSet?.current == files.first)
    other.setFolderLoopEnabled(false)
    issue345Route(.previous, session); #expect(session.filePreviewSet?.current == files.first)
    for _ in 1..<count { issue345Route(.next, session) }
    #expect(!session.isEnabled(.next)); issue345Route(.next, session)
    #expect(session.filePreviewSet?.current == files.last)
    session.setFolderLoopEnabled(true)
    var index = count - 1
    for direction in [CommandID.next, .previous] {
        for _ in 0..<(2 * count) {
            index = (index + (direction == .next ? 1 : count - 1)) % count
            issue345Route(direction, session)
            #expect(session.filePreviewSet?.current == files[index])
            #expect(session.filePreviewSet?.members == files)
        }
        #expect(session.filePreviewSet?.current == files.last)
    }
    #expect(host.opened.allSatisfy { files.contains($0) })
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true]) @MainActor
func issue345WrapEscapeKeepsLatestCurrentAndSelection(reverse: Bool) {
    let ids = sessionItems(5), host = Issue345Host(), session = ViewerSession(host: host)
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[2])
    session.select(ids[0]); session.select(ids[2], modifier: .command); session.select(ids[4], modifier: .command)
    session.focus(reverse ? ids[0] : ids[4])
    let origin = session.selection
    session.setFolderLoopEnabled(true); issue345Route(.preview, session)
    let direction: CommandID = reverse ? .previous : .next
    issue345Route(direction, session) // wrap
    for _ in 0..<3 { issue345Route(direction, session) } // another full cycle
    issue345Route(direction, session) // ordinary page after wrap
    // Both directions reach the middle selected item after a wrap, full cycle and ordinary page.
    let landed = ids[2]
    #expect(session.currentItemID == landed)
    session.setFolderLoopEnabled(false); issue345Route(.escape, session)
    #expect(session.mode == .browsing)
    #expect(session.currentItemID == landed)
    #expect(session.selection.selectedItemIDs == origin.selectedItemIDs)
    #expect(session.selection.anchorItemID == origin.anchorItemID)
    #expect(session.scrollAnchor == landed)
    // #492 owner 2026-11-04: ordinary multi paging also follows the last viewed image.
    let restored = session.selection
    issue345Route(.preview, session); issue345Route(.next, session); issue345Route(.escape, session)
    #expect(session.selection.selectedItemIDs == restored.selectedItemIDs)
    #expect(session.selection.anchorItemID == restored.anchorItemID)
    #expect(session.currentItemID == ids[4])
    #expect(session.scrollAnchor == ids[4])
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true]) @MainActor
func issue345FastPagingAcrossWrapRejectsOldDecode(finder: Bool) async throws {
    let ids = sessionItems(3), host = Issue345Host(), session = ViewerSession(host: host)
    let pipeline = GenerationPipeline(), access = LoadLeases(), imageHost = LoadHost()
    session.imageLoader.host = imageHost
    let files = ["A", "B", "C"].map { URL(fileURLWithPath: "/" + $0) }
    if finder {
        session.filePreviewSet = FilePreviewSet(files: files)
        issue345Route(.next, session); issue345Route(.next, session)
    } else {
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
        session.select(ids[2]); issue345Route(.preview, session)
    }
    var tasks: [Task<Void, Never>] = []
    func load(_ name: String) {
        if let task = generationOpen(name, session: session, pipeline: pipeline, access: access) { tasks.append(task) }
    }
    host.open = { load($0.lastPathComponent) }
    host.present = { id in load(files[ids.firstIndex(of: id)!].lastPathComponent) }
    session.setFolderLoopEnabled(true)
    issue345Route(.next, session)
    try #require(finder ? session.filePreviewSet?.current == files[0] : session.currentItemID == ids[0])
    await pipeline.entered("A")
    issue345Route(.next, session)
    await pipeline.entered("B")
    await pipeline.release("B"); await tasks[1].value
    #expect(session.imageLoader.presented?.name == "B")
    await pipeline.release("A"); await tasks[0].value
    #expect(session.imageLoader.presented?.fileURL == files[1])
    #expect(session.imageLoader.phase == .settled)
    #expect(imageHost.names == ["B", "B"])
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true]) @MainActor
func issue345WrappedRemovalReturnsSurvivingCurrent(reverse: Bool) {
    let ids = sessionItems(3), host = Issue345Host(), session = ViewerSession(host: host)
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    session.select(reverse ? ids[0] : ids[2])
    session.setFolderLoopEnabled(true); issue345Route(.preview, session)
    issue345Route(reverse ? .previous : .next, session)
    let remaining = reverse ? Array(ids.prefix(2)) : Array(ids.suffix(2))
    session.updateItems(remaining, sourceVersion: .init(2))
    #expect(session.currentItemID == ids[1])
    issue345Route(.escape, session)
    #expect(session.currentItemID == ids[1])
    #expect(session.selection.selectedItemIDs == [ids[1]])
    #expect(session.selection.anchorItemID == ids[1])
    #expect(session.scrollAnchor == ids[1])
    session.beginBrowsing(items: ids, sourceVersion: .init(3), scrollAnchor: ids[0])
    session.select(ids[2]); issue345Route(.preview, session); issue345Route(.next, session)
    session.updateItems([], sourceVersion: .init(4))
    #expect(session.mode == .browsing)
    #expect(session.currentItemID == nil)
    #expect(session.scrollAnchor == nil)
}
