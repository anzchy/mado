import AppKit
import SwiftUI
import Testing
import MadoCore
@testable import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

private struct ComboInspectorReader: InspectorMetadataReading {
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata { .init() }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136Combo2DirectSearchReconcilesInspectorCurrentAndEmpty() {
    let scene = SearchedRefreshScene()
    let model = InspectorModel(reader: ComboInspectorReader())
    let a = scene.entry("match-a.jpg"), d = scene.entry("match-d.jpg")
    let source = scene.snapshot([a, d], 1)
    scene.begin(source, term: "match", current: d.itemID)
    model.select(itemID: d.itemID, url: d.url, access: .fileGrant(d.url))
    func present(_ term: String) {
        scene.search.setTerm(term, currentItemID: scene.grid.currentItemID)
        let filtered = scene.search.project(source)
        GridSearchReconciler.present(filtered, source: source, session: scene.session,
            search: scene.search, grid: scene.grid, shell: scene.shell, onReconciled: {
                let current = scene.session.selection.currentItemID
                let entry = source.entries.first { $0.itemID == current }
                model.select(itemID: current, url: entry?.url,
                    access: entry.map { .fileGrant($0.url) })
            })
    }
    present("match-a")
    #expect(model.name == a.url.lastPathComponent)
    present("unmatched")
    #expect(model.name == nil)
    present("")
    #expect(model.name == d.url.lastPathComponent)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136ComboWatchedRefreshSynchronizesInspectorCurrentAndEmpty() {
    let scene = SearchedRefreshScene()
    let model = InspectorModel(reader: ComboInspectorReader())
    scene.session.setInspectorVisible(true)
    let panel = NSHostingView(rootView: InspectorPanel(model: model, session: scene.session,
        close: {}, restoreCanvasFocus: {}, updateFocus: { scene.session.updateFocus($0) }))
    panel.frame = NSRect(x: 780, y: 0, width: 220, height: 700)
    scene.window.contentView?.addSubview(panel)
    let a = scene.entry("match-a.jpg"), d = scene.entry("match-d.jpg")
    scene.begin(scene.snapshot([a, d], 1), term: "match", current: d.itemID)
    model.select(itemID: d.itemID, url: d.url, access: .fileGrant(d.url))
    let survivor = scene.snapshot([a], 2)
    GridWatchedSearchRefresh.apply(survivor, session: scene.session, search: scene.search,
        scheduler: scene.scheduler, grid: scene.grid, shell: scene.shell, gridVisible: true,
        onReconciled: {
            let current = scene.session.selection.currentItemID
            let entry = survivor.entries.first { $0.itemID == current }
            model.select(itemID: current, url: entry?.url,
                access: entry.map { .fileGrant($0.url) })
        })
    #expect(model.name == a.url.lastPathComponent)
    let empty = scene.snapshot([], 3)
    GridWatchedSearchRefresh.apply(empty, session: scene.session, search: scene.search,
        scheduler: scene.scheduler, grid: scene.grid, shell: scene.shell, gridVisible: true,
        onReconciled: {
            model.select(itemID: scene.session.selection.currentItemID, url: nil, access: nil)
        })
    #expect(model.name == nil)
}

@MainActor private final class SearchedRefreshHost: ViewerSessionHost {
    var hasImage = true
    var opened: [ItemID] = []
    var returns = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { opened.append(id) }
    func returnToGrid() { returns += 1 }
}

@MainActor private final class SearchedRefreshScene {
    let folder = URL(fileURLWithPath: "/tmp/mado-searched-refresh")
    let root: ItemIdentityRoot
    let shell: GridShellView
    let grid: GridBrowserView
    let window: NSWindow
    let search = GridSearchState()
    let scheduler = GridSearchProjectionScheduler()
    let host = SearchedRefreshHost()
    let session: ViewerSession
    init() {
        _ = NSApplication.shared
        root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700),
            preferencesStore: InMemoryDisplayPreferencesStore())
        grid = GridBrowserView(frame: shell.mainFrame)
        window = NSWindow(contentRect: shell.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        session = ViewerSession(host: host)
        shell.mainContent.addSubview(grid)
        window.contentView = shell
        shell.layoutSubtreeIfNeeded()
    }
    func entry(_ name: String) -> FolderEntry { FolderEntry(url: folder.appendingPathComponent(name), root: root) }
    func snapshot(_ entries: [FolderEntry], _ generation: UInt64) -> FolderSnapshot {
        FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: generation),
            entries: entries, isComplete: true)
    }
    func begin(_ source: FolderSnapshot, term: String, current: ItemID) {
        search.setTerm(term, currentItemID: current)
        shell.setSearchTerm(term)
        let filtered = search.project(source)
        session.beginBrowsing(items: filtered.navigationEntries.map(\.itemID),
            sourceVersion: .init(source.version.generation), scrollAnchor: nil)
        session.focus(current)
        grid.display(filtered, selection: session.selection)
        grid.setCurrentItemID(current)
        shell.focusSearch()
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedSearchedGridKeepsNearestSurvivorAndSearchFocus() async {
    let scene = SearchedRefreshScene()
    let entries = ["match-a.jpg", "match-b.jpg", "match-c.jpg", "match-d.jpg"].map(scene.entry)
    scene.begin(scene.snapshot(entries, 1), term: "match", current: entries[2].itemID)
    let responder = scene.window.firstResponder
    #expect(scene.shell.searchField.currentEditor() != nil)
    let stale = scene.snapshot(entries, 1)
    scene.scheduler.schedule(stale, term: "match") { _ in
        scene.grid.setCurrentItemID(entries[0].itemID)
    }
    let refreshed = scene.snapshot([entries[0], entries[1], entries[3]], 2)
    GridWatchedSearchRefresh.apply(refreshed, session: scene.session, search: scene.search,
        scheduler: scene.scheduler, grid: scene.grid, shell: scene.shell, gridVisible: true)
    await scene.scheduler.waitForPending()
    try? await Task.sleep(for: .milliseconds(180))
    #expect(scene.grid.currentItemID == entries[3].itemID)
    #expect(scene.session.selection.currentItemID == entries[3].itemID)
    #expect(scene.search.term == "match")
    #expect(scene.window.firstResponder === responder)
    #expect(scene.grid.displayedItemIDs == [entries[0], entries[1], entries[3]].map(\.itemID))
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedSearchFallsBackWhenFullListSurvivorIsFilteredOut() {
    let scene = SearchedRefreshScene()
    let a = scene.entry("match-a.jpg"), hidden = scene.entry("other-b.jpg")
    let c = scene.entry("match-c.jpg"), d = scene.entry("match-d.jpg")
    scene.begin(scene.snapshot([a, c, d], 1), term: "match", current: a.itemID)
    let refreshed = scene.snapshot([hidden, c, d], 2)
    GridWatchedSearchRefresh.apply(refreshed, session: scene.session, search: scene.search,
        scheduler: scene.scheduler, grid: scene.grid, shell: scene.shell, gridVisible: true)
    #expect(scene.grid.currentItemID == c.itemID)
    #expect(scene.session.selection.currentItemID == c.itemID)
    #expect(scene.grid.displayedItemIDs == [c.itemID, d.itemID])
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedSearchViewerReturnKeepsOnlyMatchesForNavigationAndStatus() {
    let scene = SearchedRefreshScene(), router = CommandRouter()
    let cat1 = scene.entry("cat-1.jpg"), dog = scene.entry("dog.jpg")
    let cat2 = scene.entry("cat-2.jpg"), cat3 = scene.entry("cat-3.jpg")
    scene.begin(scene.snapshot([cat1, dog, cat2], 1), term: "cat", current: cat2.itemID)
    #expect(router.route(.preview, from: .key, to: scene.session))
    scene.grid.isHidden = true
    let refreshed = scene.snapshot([cat1, dog, cat2, cat3], 2)
    GridWatchedSearchRefresh.apply(refreshed, session: scene.session, search: scene.search,
        scheduler: scene.scheduler, grid: scene.grid, shell: scene.shell, gridVisible: false)
    #expect(router.route(.escape, from: .key, to: scene.session))
    GridWatchedSearchRefresh.restoreGrid(refreshed, session: scene.session,
        search: scene.search, grid: scene.grid, shell: scene.shell)
    #expect(scene.grid.displayedItemIDs == [cat1, cat2, cat3].map(\.itemID))
    #expect(scene.shell.searchStatus.stringValue.contains("3"))
    #expect(router.route(.preview, from: .key, to: scene.session))
    #expect(router.route(.next, from: .key, to: scene.session))
    #expect(router.route(.previous, from: .key, to: scene.session))
    #expect(Array(scene.host.opened.suffix(3)) == [cat2, cat3, cat2].map(\.itemID))
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedSearchViewerReturnShowsNoResultWhenLastMatchDisappears() {
    let scene = SearchedRefreshScene(), router = CommandRouter()
    let cat = scene.entry("cat.jpg"), dog = scene.entry("dog.jpg")
    scene.begin(scene.snapshot([cat, dog], 1), term: "cat", current: cat.itemID)
    #expect(router.route(.preview, from: .key, to: scene.session))
    scene.grid.isHidden = true
    let refreshed = scene.snapshot([dog], 2)
    GridWatchedSearchRefresh.apply(refreshed, session: scene.session, search: scene.search,
        scheduler: scene.scheduler, grid: scene.grid, shell: scene.shell, gridVisible: false)
    GridWatchedSearchRefresh.restoreGrid(refreshed, session: scene.session,
        search: scene.search, grid: scene.grid, shell: scene.shell)
    #expect(scene.host.returns == 1)
    #expect(scene.shell.searchEmptyVisible)
    #expect(scene.grid.displayedItemIDs.isEmpty)
    #expect(!router.route(.preview, from: .key, to: scene.session))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue140WatchedFilenameSearchRenameThenDeleteKeepsFocusAndMatch() {
    let scene = SearchedRefreshScene()
    let a = scene.entry("match-a.jpg"), b = scene.entry("match-b.jpg")
    let c = scene.entry("match-c.jpg"), hidden = scene.entry("other.jpg")
    scene.begin(scene.snapshot([a, b, c, hidden], 1), term: "match", current: b.itemID)
    let responder = scene.window.firstResponder
    let renamed = FolderEntry(url: scene.folder.appendingPathComponent("match-d.jpg"),
        root: scene.root, itemID: b.itemID)
    GridWatchedSearchRefresh.apply(scene.snapshot([a, c, renamed, hidden], 2),
        session: scene.session, search: scene.search, scheduler: scene.scheduler,
        grid: scene.grid, shell: scene.shell, gridVisible: true)
    #expect(scene.grid.currentItemID == b.itemID)
    #expect(scene.grid.displayedItemIDs == [a, c, renamed].map(\.itemID))
    #expect(!scene.shell.searchEmptyVisible && scene.window.firstResponder === responder)

    GridWatchedSearchRefresh.apply(scene.snapshot([a, c, hidden], 3),
        session: scene.session, search: scene.search, scheduler: scene.scheduler,
        grid: scene.grid, shell: scene.shell, gridVisible: true)
    #expect(scene.grid.currentItemID == c.itemID)
    #expect(scene.grid.displayedItemIDs == [a, c].map(\.itemID))
    #expect(scene.session.selection.currentItemID == c.itemID)
    #expect(scene.search.term == "match")
    #expect(!scene.shell.searchEmptyVisible && scene.shell.searchStatus.stringValue.contains("2"))
    #expect(scene.window.firstResponder === responder)
}
