import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private final class Issue345Motion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue345Grid(_ view: NSView?) -> GridBrowserView? {
    guard let view else { return nil }
    if let grid = view as? GridBrowserView { return grid }
    return view.subviews.lazy.compactMap { issue345Grid($0) }.first
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue345GridSpaceMenuWrapEscapeReturnsVisibleCurrentItem() async throws {
    _ = NSApplication.shared
    let oldMenu = NSApp.mainMenu
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("issue345-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("Images")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    for i in 0..<48 { try data.write(to: folder.appendingPathComponent(String(format: "%03d.png", i))) }
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue345")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let store = InMemoryDisplayPreferencesStore()
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue345Motion()))
    let window = try #require(controller.window)
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {}, openDiagnostics: {},
        windowController: { controller })
    defer { window.close(); NSApp.mainMenu = oldMenu; withExtendedLifetime(menu) {} }
    window.setContentSize(NSSize(width: 900, height: 620))
    func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    controller.openGrantedFolder(folder)
    try await waitUntil { controller.gridSearchAvailable }
    let grid = try #require(issue345Grid(window.contentView))
    window.contentView?.layoutSubtreeIfNeeded()
    let scrollView = try #require(grid.collectionView.enclosingScrollView)
    let ids = grid.displayedItemIDs
    try #require(ids.count == 48)
    let first = ids[0], last = ids[47]
    controller.session.select(last)
    grid.synchronizeSelection(controller.session.selection)
    grid.scrollTo(last)
    window.contentView?.layoutSubtreeIfNeeded()
    let firstFrame = grid.collectionView.frameForItem(at: 0)
    #expect(!scrollView.contentView.documentVisibleRect.intersects(firstFrame), "start at last, first offscreen")
    let selected = controller.session.selection.selectedItemIDs
    // .preview is the Space command, routed through the controller to capture the actual Grid offset.
    #expect(controller.route(.preview, from: .key))
    try await waitUntil { controller.session.imageLoader.phase == .settled }
    #expect(controller.session.imageLoader.presented?.fileURL.lastPathComponent == "047.png")
    let main = try #require(NSApp.mainMenu)
    let view = try #require(main.items.first { $0.title == String(localized: "View") }?.submenu)
    let item = try #require(view.items.first { $0.accessibilityIdentifier() == "folder.loop.menu" })
    #expect(item.title == String(localized: "Loop Through Images"))
    #expect(menu.validateMenuItem(item)); #expect(item.state == .off)
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(menu.validateMenuItem(item)); #expect(item.state == .on)
    #expect(controller.route(.next, from: .key))
    // Fail immediately on the pre-fix target instead of waiting forever for an impossible decode.
    try #require(controller.session.currentItemID == first)
    try await waitUntil { controller.session.imageLoader.phase == .settled }
    #expect(controller.session.imageLoader.presented?.fileURL.lastPathComponent == "000.png")
    #expect(controller.session.imageLoader.presented?.key.itemID == first)
    #expect(controller.route(.escape, from: .key))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(controller.session.mode == .browsing)
    #expect(controller.session.currentItemID == first)
    #expect(grid.currentItemID == first)
    #expect(controller.session.selection.selectedItemIDs == selected)
    #expect(menu.validateMenuItem(item)); #expect(item.state == .on)
    #expect(item.title == String(localized: "Loop Through Images"))
    var visible = scrollView.contentView.documentVisibleRect
    visible.origin.y += scrollView.contentInsets.top
    visible.size.height -= scrollView.contentInsets.top + scrollView.contentInsets.bottom
    #expect(visible.contains(grid.collectionView.frameForItem(at: 0)), "wrapped current tile fully visible after Esc")
}
