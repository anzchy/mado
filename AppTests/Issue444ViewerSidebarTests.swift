import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #444 in the real window: 侧栏 / 返回网格 / 更多 and the viewer's folder sidebar beside a preview from the grid.

@MainActor private final class Issue444Motion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor private final class Issue444Presenter: ChromeMenuPresenting {
    var inside: ((NSMenu) -> Void)?
    var presented: [NSMenu] = []
    func present(_ menu: NSMenu, from view: NSView) { presented.append(menu); inside?(menu) }
}

@MainActor private func issue444Find(_ view: NSView?, _ match: (NSView) -> Bool) -> NSView? {
    guard let view else { return nil }
    if match(view) { return view }
    for child in view.subviews { if let found = issue444Find(child, match) { return found } }
    return nil
}

@MainActor private func issue444Items(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(issue444Items) ?? []) }
}

@MainActor private final class Issue444Scene {
    let base: URL
    let folder: URL
    let store = InMemoryDisplayPreferencesStore()
    let controller: CanvasWindowController
    let window: NSWindow
    let menu: CommandMenu
    let oldMenu: NSMenu?
    var shortcuts = 0
    var opens = 0
    init(count: Int = 6) throws {
        _ = NSApplication.shared
        oldMenu = NSApp.mainMenu
        base = FileManager.default.temporaryDirectory.appendingPathComponent("issue444-\(UUID().uuidString)")
        folder = base.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: fixture)
        for i in 0..<count { try data.write(to: folder.appendingPathComponent(String(format: "%03d.png", i))) }
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue444")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue444Motion()))
        self.controller = controller
        window = try #require(controller.window)
        var counter: (() -> Void)?
        menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {}, openDiagnostics: {},
                           openShortcuts: { counter?() }, windowController: { controller })
        counter = { [unowned self] in self.shortcuts += 1 }
        controller.onOpenRequest = { [unowned self] in self.opens += 1 }
        window.setContentSize(NSSize(width: 1280, height: 800))
    }
    func close() {
        window.close()
        NSApp.mainMenu = oldMenu
        try? FileManager.default.removeItem(at: base)
    }
    func layout() { window.contentView?.layoutSubtreeIfNeeded() }
    func waitUntil(_ condition: () -> Bool, fileID: String = #fileID, line: Int = #line) async throws {
        try await MadoAppTests.waitUntil(fileID: fileID, line: line, between: { self.layout() }, condition)
    }
    var content: NSView { window.contentView! }
    var grid: GridBrowserView? { issue444Find(content) { $0 is GridBrowserView } as? GridBrowserView }
    var shell: GridShellView? { issue444Find(content) { $0 is GridShellView } as? GridShellView }
    var canvas: NSView? { issue444Find(content) { $0.accessibilityIdentifier() == "viewer.canvas" } }
    var overlay: ViewerChromeOverlay? { issue444Find(content) { $0 is ViewerChromeOverlay } as? ViewerChromeOverlay }
    func tool(_ id: String) -> ChromeToolView? { overlay?.tools.first { $0.accessibilityIdentifier() == id } }
    var sidebarItem: NSMenuItem? {
        NSApp.mainMenu.map(issue444Items)?.first { $0.identifier?.rawValue == "grid.sidebar.toggle.menu" }
    }
    var gridVisible: Bool { grid.map { !$0.isHidden } ?? false }
    var inViewer: Bool { controller.session.mode == .viewing && controller.session.previewSet != nil }
    func openGrid() async throws {
        controller.openGrantedFolder(folder)
        try await waitUntil { self.controller.gridSearchAvailable && (self.grid?.displayedItemIDs.count ?? 0) > 0 }
    }
    func enterViewer(at index: Int = 2) async throws {
        let ids = try #require(grid?.displayedItemIDs)
        controller.session.select(ids[index])
        grid?.synchronizeSelection(controller.session.selection)
        _ = controller.route(.enter, from: .key)
        // Image commands (zoom, Inspector) need the image shown, not just chosen.
        try await waitUntil { self.inViewer && self.controller.session.imageLoader.phase == .settled && self.controller.hasImage }
        layout()
    }
    func fireSidebarItem() throws {
        let item = try #require(sidebarItem)
        _ = menu.validateMenuItem(item)
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        layout()
    }
    /// The viewer's sidebar starts hidden (owner decision 2026-11-04); ⌃⌘S shows it for this viewing.
    func showViewerSidebar() throws {
        try #require(!controller.session.isViewerSidebarShown)
        try fireSidebarItem()
        try #require(controller.session.isViewerSidebarShown && shell?.isHidden == false)
    }
}

/// Owner decision 2026-11-04 (#444): 进入大图时侧栏默认隐藏；在大图里点「显示侧栏」后，在这次查看中保持，返回网格时网格侧栏照旧。
/// ⌃⌘S toggles the viewer's own sidebar; it never changes the grid's, and each entry starts hidden.
@Test(.timeLimit(.minutes(3))) @MainActor func i444CtrlCmdSTogglesTheViewersOwnSidebar() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    let item = try #require(scene.sidebarItem)
    let shell = try #require(scene.shell)
    let width = CGFloat(scene.store.value.gridSidebarWidth)
    #expect(scene.store.value.gridSidebarVisible && !shell.sidebar.isHidden, "the grid shows its sidebar")
    try await scene.enterViewer()
    let canvas = try #require(scene.canvas)
    #expect(shell.isHidden && canvas.frame.minX == 0, "entry from a grid with its sidebar shown starts hidden")
    #expect(scene.menu.validateMenuItem(item) && item.title == "Show sidebar")
    try scene.fireSidebarItem()
    #expect(!shell.isHidden && canvas.frame.minX == width, "⌃⌘S shows it beside the image")
    #expect(scene.menu.validateMenuItem(item) && item.title == "Hide sidebar")
    #expect(scene.store.value.gridSidebarVisible, "the grid's preference is untouched")
    try scene.fireSidebarItem()
    #expect(shell.isHidden && canvas.frame.width == scene.content.bounds.width && scene.store.value.gridSidebarVisible)
    try scene.fireSidebarItem()
    _ = scene.controller.route(.escape, from: .key)
    try await scene.waitUntil { scene.gridVisible }
    #expect(shell.isGridSurface && !shell.sidebar.isHidden && scene.store.value.gridSidebarVisible,
            "returning shows the grid's sidebar as it was")
    try scene.fireSidebarItem()
    #expect(!scene.store.value.gridSidebarVisible && shell.sidebar.isHidden, "in the grid ⌃⌘S is the grid's own")
    try await scene.enterViewer(at: 1)
    #expect(shell.isHidden && canvas.frame.minX == 0, "the next entry starts hidden again")
    try scene.fireSidebarItem()
    #expect(!shell.isHidden && !scene.store.value.gridSidebarVisible, "showing it in the viewer leaves the grid's hidden")
    _ = scene.controller.route(.escape, from: .key)
    try await scene.waitUntil { scene.gridVisible }
    #expect(shell.isGridSurface && shell.sidebar.isHidden && !scene.store.value.gridSidebarVisible)
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444SidebarMenuItemValidationTable() async throws {
    for visible in [true, false] {
        let scene = try Issue444Scene()
        defer { scene.close() }
        scene.store.value.gridSidebarVisible = visible
        let item = try #require(scene.sidebarItem)
        func check(_ surface: String, _ expected: Bool, shown: Bool? = nil) {
            #expect(scene.menu.validateMenuItem(item) == expected, "\(surface) visible \(visible)")
            #expect(item.title == ((shown ?? visible) ? "Hide sidebar" : "Show sidebar"), "\(surface)")
            if surface != "grid", surface != "home" {
                #expect(scene.tool("chrome.sidebar.button")?.isEnabled == expected, "\(surface) tool")
            }
        }
        check("home", false)
        try await scene.openGrid()
        check("grid", true)
        try await scene.enterViewer()
        check("viewer from grid", true, shown: false)  // the viewer's own sidebar starts hidden
        scene.controller.open(scene.folder.appendingPathComponent("004.png"))
        try await scene.waitUntil { scene.controller.session.imageLoader.fileURL?.lastPathComponent == "004.png" }
        check("single image", false)
    }
}

@Test(.timeLimit(.minutes(4)), arguments: [0, 3, 5]) @MainActor
func i444ReturnToGridToolMatchesEscapeOnTwinControllers(index: Int) async throws {
    let a = try Issue444Scene(), b = try Issue444Scene()
    defer { a.close(); b.close() }
    for scene in [a, b] {
        try await scene.openGrid()
        try await scene.enterViewer(at: index)
        _ = scene.controller.route(.next, from: .key)
        try await scene.waitUntil { scene.controller.session.currentItemID != nil }
    }
    let tool = try #require(a.tool("chrome.returnToGrid.button"))
    #expect(tool.isEnabled)
    #expect(tool.accessibilityPerformPress())
    _ = b.controller.route(.escape, from: .key)
    try await a.waitUntil { a.gridVisible }
    try await b.waitUntil { b.gridVisible }
    let aIDs = try #require(a.grid?.displayedItemIDs), bIDs = try #require(b.grid?.displayedItemIDs)
    func position(_ id: ItemID?, _ ids: [ItemID]) -> Int? { id.flatMap { ids.firstIndex(of: $0) } }
    #expect(position(a.controller.session.selection.currentItemID, aIDs) == position(b.controller.session.selection.currentItemID, bIDs))
    #expect(a.controller.session.selection.selectedItemIDs.compactMap { aIDs.firstIndex(of: $0) }.sorted()
        == b.controller.session.selection.selectedItemIDs.compactMap { bIDs.firstIndex(of: $0) }.sorted())
    #expect(position(a.grid?.currentItemID, aIDs) == position(b.grid?.currentItemID, bIDs))
    #expect(a.grid?.contentOffset == b.grid?.contentOffset)
    #expect(a.controller.session.mode == .browsing && b.controller.session.mode == .browsing)
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444MoreMenuStructureAndTwins() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer(at: 3)
    scene.store.value.alwaysShowTools = true
    scene.store.value.appearance = .dark
    let mainItems = try #require(NSApp.mainMenu.map(issue444Items))
    for inspector in [false, true] {
        if scene.controller.inspectorVisible != inspector { _ = scene.controller.route(.inspector, from: .menu) }
        let menu = try #require(scene.overlay?.moreMenuProvider?())
        menu.update()
        menu.items.compactMap(\.submenu).forEach { $0.update() }
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            == ["003.png", inspector ? "Hide image information" : "Show image information", "—",
                "Appearance", "Always Show Tools", "Keyboard Shortcuts"], "inspector \(inspector)")
        try #require(menu.items.count == 6)
        #expect(!menu.items[0].isEnabled, "the file name header is not a command")
        #expect(!menu.items.contains { $0.title.contains("avorite") || $0.title.contains("ilmstrip") || $0.title.contains("收藏") })
        #expect(menu.items[4].state == .on)
        let appearance = try #require(menu.items[3].submenu)
        #expect(appearance.items.map(\.state) == [.off, .off, .on])
        // A submenu's parent item carries AppKit's submenuAction:; only command items have twins.
        for item in issue444Items(menu) where item.action != nil && item.submenu == nil {
            let twin = mainItems.first {
                $0.action == item.action && ($0.representedObject as? String) == (item.representedObject as? String)
            }
            #expect(twin != nil, "\(item.title) has a main-menu twin")
            if let twin, item.identifier?.rawValue != "viewer.more.inspector" {
                _ = scene.menu.validateMenuItem(twin)
                #expect(twin.title == item.title && twin.state == item.state, "\(item.title)")
            }
        }
        let mainInspector = try #require(mainItems.first { ($0.representedObject as? String) == "inspector" && $0.identifier?.rawValue != "viewer.more.inspector" })
        _ = scene.menu.validateMenuItem(mainInspector)
        #expect(mainInspector.title == (inspector ? "Hide Inspector" : "Show Inspector"), "View menu wording unchanged")
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444MoreMenuItemsTakeEffect() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer()
    func more() throws -> NSMenu { try #require(scene.overlay?.moreMenuProvider?()) }
    try more().performActionForItem(at: 1)
    scene.layout()
    #expect(scene.controller.inspectorVisible)
    for (index, expected) in [DisplayAppearance.system, .light, .dark].enumerated() {
        let appearance = try #require(try more().items[3].submenu)
        appearance.performActionForItem(at: index)
        #expect(scene.store.value.appearance == expected)
    }
    let always = scene.store.value.alwaysShowTools
    try more().performActionForItem(at: 4)
    #expect(scene.store.value.alwaysShowTools == !always)
    try more().performActionForItem(at: 5)
    #expect(scene.shortcuts == 1)
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444OpenAndInspectorStillReachableInViewer() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer()
    let items = try #require(NSApp.mainMenu.map(issue444Items))
    let open = try #require(items.first { ($0.representedObject as? String) == "open" })
    let inspector = try #require(items.first { ($0.representedObject as? String) == "inspector" && $0.identifier?.rawValue != "viewer.more.inspector" })
    #expect(scene.menu.validateMenuItem(open) && open.keyEquivalent == "o")
    #expect(scene.menu.validateMenuItem(inspector) && inspector.keyEquivalent == "i")
    NSApp.sendAction(try #require(inspector.action), to: inspector.target, from: inspector)
    scene.layout()
    #expect(scene.controller.inspectorVisible)
    NSApp.sendAction(try #require(open.action), to: open.target, from: open)
    #expect(scene.opens == 1)
    let ids = scene.overlay?.tools.map { $0.accessibilityIdentifier() } ?? []
    #expect(!ids.contains("command.open.button") && !ids.contains("command.inspector.button"))
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444KeysWorkWithSidebarShown() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer(at: 1)
    let shell = try #require(scene.shell), canvas = try #require(scene.canvas)
    try scene.showViewerSidebar()
    let before = scene.controller.session.currentItemID
    _ = scene.controller.route(.next, from: .key)
    #expect(scene.controller.session.currentItemID != before)
    try await scene.waitUntil { scene.controller.session.imageLoader.phase == .settled && scene.controller.hasImage }
    _ = scene.controller.route(.actualPixels, from: .key)
    #expect(scene.controller.session.zoomMode == .actualPixels)
    _ = scene.controller.route(.fit, from: .key)
    #expect(scene.controller.session.zoomMode == .fit)
    #expect(scene.window.makeFirstResponder(canvas))
    // Tab through the enabled tools, then into the sidebar: the resize divider, then every folder row.
    let tools = scene.overlay?.tools.filter(\.acceptsFirstResponder) ?? []
    for _ in tools { scene.controller.session.tab(reverse: false) }
    #expect(scene.window.firstResponder === tools.last)
    scene.controller.session.tab(reverse: false)
    #expect(scene.window.firstResponder.map { $0 === shell.viewerSidebarKeyViews.first } == true, "Tab enters the sidebar")
    // Real Tab keys through the window: the sidebar's divider and rows do not handle Tab themselves.
    func tabKey(shift: Bool = false) throws {
        scene.window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: scene.window.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
    }
    for _ in shell.viewerSidebarKeyViews.dropFirst() { try tabKey() }
    #expect(scene.window.firstResponder.map { $0 === shell.viewerSidebarKeyViews.last } == true)
    try tabKey()
    #expect(scene.window.firstResponder === canvas, "the loop wraps to the canvas")
    #expect(scene.controller.session.inspectorFocus.focus == .canvas)
    #expect(!scene.controller.session.chrome.locks.contains(.keyboardFocus))
    try tabKey(shift: true)
    #expect(scene.window.firstResponder.map { $0 === shell.viewerSidebarKeyViews.last } == true, "Shift-Tab enters the last row")
    try tabKey(shift: true)
    #expect(scene.window.firstResponder.map { $0 === shell.viewerSidebarKeyViews.dropLast().last } == true, "Shift-Tab walks back up the rows")
    try tabKey()
    // Hiding the sidebar with ⌃⌘S while a row holds focus hands focus to the canvas, not the hidden footer.
    let row = try #require(shell.viewerSidebarKeyViews.dropFirst(2).first ?? shell.viewerSidebarKeyViews.last)
    #expect(scene.window.makeFirstResponder(row))
    try scene.fireSidebarItem()
    #expect(scene.window.firstResponder === canvas && shell.isHidden)
    #expect(scene.controller.session.inspectorFocus.focus == .canvas)
    let cycle = (scene.overlay?.tools.filter(\.acceptsFirstResponder).count ?? 0) + 1
    for _ in 0..<cycle {
        scene.controller.session.tab(reverse: false)
        #expect((scene.window.firstResponder as? NSView)?.isDescendant(of: shell) != true)
    }
    #expect(scene.window.makeFirstResponder(canvas))
    scene.controller.session.updateFocus(.canvas)
    _ = scene.controller.route(.escape, from: .key)
    try await scene.waitUntil { scene.gridVisible }
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444GridOnlyPathsInertInViewerWithSidebar() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer()
    try scene.showViewerSidebar()
    let shell = try #require(scene.shell), canvas = try #require(scene.canvas)
    let frame = canvas.frame
    #expect(!shell.isHidden && !shell.isGridSurface && shell.footer.isHidden)
    #expect(!scene.controller.gridSearchAvailable && !scene.controller.gridShellVisible)
    _ = scene.controller.route(.search, from: .menu)
    #expect(scene.window.firstResponder !== shell.searchField && scene.window.firstResponder !== shell.searchField.currentEditor())
    scene.controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: scene.window))
    scene.layout()
    #expect(shell.footer.isHidden && shell.mode == .viewerSidebar && canvas.frame == frame)
}

@Test(.timeLimit(.minutes(3)), arguments: ["single", "grid-return"]) @MainActor
func i444SidebarVisibilityInvariantAcrossSourceTransitions(step: String) async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer()
    let width = CGFloat(scene.store.value.gridSidebarWidth)
    func check(_ label: String) throws {
        scene.layout()
        let shell = try #require(scene.shell), canvas = try #require(scene.canvas), overlay = try #require(scene.overlay)
        let session = scene.controller.session
        if !scene.gridVisible {
            #expect(!shell.isHidden == session.isViewerSidebarShown, "\(label)")
            #expect(canvas.frame.minX == (session.isViewerSidebarShown ? width : 0), "\(label) canvas \(canvas.frame)")
            #expect(overlay.frame == canvas.frame, "\(label)")
        }
        #expect(scene.tool("chrome.sidebar.button")?.isEnabled == session.canToggleViewerSidebar, "\(label)")
        #expect(scene.tool("chrome.returnToGrid.button")?.isEnabled == session.canReturnToSource, "\(label)")
    }
    try check("viewer from grid")
    #expect(!scene.controller.session.isViewerSidebarShown, "it starts hidden")
    try scene.showViewerSidebar()
    try check("viewer with its sidebar shown")
    if step == "single" {
        scene.controller.open(scene.folder.appendingPathComponent("005.png"))
        try await scene.waitUntil { scene.controller.session.imageLoader.fileURL?.lastPathComponent == "005.png" }
        try check("single file")
        #expect(scene.shell?.isHidden == true && scene.canvas?.frame.width == scene.content.bounds.width)
    } else {
        _ = scene.controller.route(.escape, from: .key)
        try await scene.waitUntil { scene.gridVisible }
        try check("grid")
        try await scene.enterViewer(at: 4)
        try check("viewer again")
        #expect(scene.shell?.isHidden == true, "the next viewing starts hidden")
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func i444MoreSubmenuCloseKeepsMenuLock() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer()
    let presenter = Issue444Presenter()
    let overlay = try #require(scene.overlay)
    overlay.menuPresenter = presenter
    var checked = false
    presenter.inside = { menu in
        guard let appearance = menu.items.first(where: { $0.submenu != nil })?.submenu else { return }
        scene.menu.menuWillOpen(appearance)
        scene.menu.menuDidClose(appearance)
        scene.controller.session.advanceChrome()
        #expect(scene.controller.session.isMenuTracking)
        #expect(scene.controller.session.chrome.locks.contains(.menu))
        #expect(!scene.controller.session.chrome.isHidden)
        checked = true
    }
    let more = try #require(scene.tool("chrome.more.button"))
    more.activate()
    #expect(checked && presenter.presented.count == 1)
    #expect(!scene.controller.session.chrome.locks.contains(.menu))
}

/// Decision A (delegator, 2026-11-04): unchanged grid behaviour. A sidebar folder row clicked while the viewer shows
/// the sidebar leaves the viewer for that folder's grid, as the same row does in the grid (Finder-sidebar style).
@Test(.timeLimit(.minutes(3))) @MainActor func i444SidebarRowClickInViewerOpensThatFoldersGrid() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    let sub = scene.folder.appendingPathComponent("Sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: scene.folder.appendingPathComponent("000.png"), to: sub.appendingPathComponent("a.png"))
    try await scene.openGrid()
    try await scene.enterViewer()
    try scene.showViewerSidebar()
    let shell = try #require(scene.shell)
    #expect(!shell.isHidden && shell.mode == .viewerSidebar)
    func subRow() -> GridSidebarFolderButton? {
        shell.folderTree.rows.first { $0.folderURL.standardizedFileURL.path == sub.standardizedFileURL.path }
    }
    try await scene.waitUntil { subRow() != nil }
    try #require(subRow()).performClick(nil)
    try await scene.waitUntil { scene.gridVisible && scene.controller.gridSearchAvailable && scene.grid?.displayedItemIDs.count == 1 }
    #expect(scene.controller.session.mode == .browsing && scene.controller.session.previewSet == nil)
    #expect(shell.mode == .grid && !shell.isHidden)
}

@MainActor private func issue444TabKey(_ window: NSWindow, shift: Bool = false) throws {
    window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
}

/// Fix round 1 (gpt H1): with the Inspector shown beside a viewer that shows its sidebar, real Tab keys walk
/// canvas → tools → sidebar → Inspector → canvas, and Shift-Tab walks the same ring backwards; the Inspector is
/// never skipped and native focus always matches the Session's focus.
@Test(.timeLimit(.minutes(3))) @MainActor func i444TabReachesTheVisibleInspectorBothWays() async throws {
    let scene = try Issue444Scene()
    defer { scene.close() }
    try await scene.openGrid()
    try await scene.enterViewer()
    try scene.showViewerSidebar()
    _ = scene.controller.route(.inspector, from: .menu)
    scene.layout()
    #expect(scene.controller.inspectorVisible)
    let shell = try #require(scene.shell), canvas = try #require(scene.canvas)
    let close = try #require(issue444Find(scene.content) { $0.accessibilityIdentifier() == "inspector.close" })
    let tools = (scene.overlay?.tools ?? []).filter(\.acceptsFirstResponder)
    let ring: [NSView] = [canvas] + tools + shell.viewerSidebarKeyViews + [close]
    func focused(_ label: String) -> NSResponder? {
        scene.layout()
        return scene.window.firstResponder
    }
    #expect(scene.window.makeFirstResponder(canvas))
    scene.controller.session.updateFocus(.canvas)
    for step in 1...ring.count {
        try issue444TabKey(scene.window)
        let expected = ring[step % ring.count]
        #expect(focused("tab \(step)") === expected, "Tab \(step): \(String(describing: scene.window.firstResponder)) ≠ \(expected)")
    }
    #expect(scene.window.firstResponder === canvas && scene.controller.session.inspectorFocus.focus == .canvas)
    for step in 1...ring.count {
        try issue444TabKey(scene.window, shift: true)
        let expected = ring[(ring.count - step) % ring.count]
        #expect(focused("shift-tab \(step)") === expected, "Shift-Tab \(step): \(String(describing: scene.window.firstResponder)) ≠ \(expected)")
    }
    #expect(scene.window.firstResponder === canvas && scene.controller.session.inspectorFocus.focus == .canvas)
}
