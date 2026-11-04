import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

// #444 owner acceptance: in the viewer, 显示侧栏 shows the grid's folder sidebar to the left of the large image;
// the canvas narrows, and the grid and the viewer share one sidebar visibility. The sidebar keeps the grid's
// height (content height − 28, under the title-bar strip); canvas, tools and states keep the full height.

/// Records every responder change the way the App's CommandWindow observes them (AppKit's hide hand-off included).
@MainActor final class Sidebar444Window: NSWindow {
    var visited: [NSResponder] = []
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let responder { visited.append(responder) }
        return accepted
    }
}

@MainActor final class Sidebar444Canvas: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor struct Sidebar444Scene {
    let window: Sidebar444Window
    let content: NSView
    let shell: GridShellView
    let chrome: ViewerChromeOverlay
    let state: ViewerStateHost
    let canvas: NSView
    let inspector = NSView()
    let grid = NSView()
    let presentation: GridViewerPresentation
    let store = InMemoryDisplayPreferencesStore()
    let session: ViewerSession
    let host = Pods444Host()
    var inspectorVisible = false
    /// `visible` shows the viewer's own sidebar after entry (it starts hidden); `gridVisible` is the grid's preference.
    init(size: NSSize = NSSize(width: 1280, height: 800), sidebarWidth: Double = 196, visible: Bool = true,
         gridVisible: Bool = true, available: Bool = true, inspector inspectorVisible: Bool = false,
         canvas: ((ViewerSession) -> NSView)? = nil) {
        _ = NSApplication.shared
        store.value.gridSidebarWidth = sidebarWidth
        store.value.gridSidebarVisible = gridVisible
        host.store = store; host.available = available
        session = ViewerSession(preferencesStore: store, host: host)
        let items = (0..<3).map { _ in ItemID.ephemeral(UUID()) }
        session.beginBrowsing(items: items, sourceVersion: .init(1), scrollAnchor: nil)
        session.select(items[1])
        CommandRouter().route(.preview, from: .key, to: session)
        window = Sidebar444Window(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        self.canvas = canvas?(session) ?? Sidebar444Canvas()
        self.canvas.frame = content.bounds
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 28)),
                              preferencesStore: store)
        shell.session = session
        state = ViewerStateHost(frame: content.bounds, session: session)
        chrome = ViewerChromeOverlay(frame: content.bounds, session: session)
        content.addSubview(self.canvas)
        content.addSubview(shell)
        content.addSubview(state, positioned: .above, relativeTo: shell)
        content.addSubview(inspector, positioned: .above, relativeTo: state)
        content.addSubview(chrome, positioned: .above, relativeTo: inspector)
        host.overlay = chrome
        session.chromeHost = host
        presentation = GridViewerPresentation(canvas: self.canvas, chrome: chrome, state: state,
                                              grid: grid, inspector: inspector, shell: shell)
        shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/photos"), count: 3), parent: nil,
            children: ["a", "b", "c"].map { GridSidebarFolder(url: URL(fileURLWithPath: "/photos/\($0)"), count: 1) })
        presentation.showGrid(reading: false)
        presentation.layoutInspector(visible: false)
        presentation.viewerSidebarAvailable = available
        presentation.showViewer()
        if visible { session.perform(intent: .toggleSidebar) }
        self.inspectorVisible = inspectorVisible
        inspector.isHidden = !inspectorVisible
        presentation.layoutInspector(visible: inspectorVisible)
        content.layoutSubtreeIfNeeded()
        chrome.refresh(filename: "a.png")
        state.linkKeyViews(to: self.canvas, chrome: chrome)
    }
    var width: CGFloat { content.bounds.width }
    var panel: CGFloat {
        inspectorVisible && !InspectorPanelLayout.overlaysContent(at: width)
            ? min(InspectorPanelLayout.width(for: width), width) : 0
    }
    /// 显示侧栏 / ⌃⌘S in the viewer: the Session flips its own state; the window re-lays out (as the App does).
    func toggle() {
        session.perform(intent: .toggleSidebar)
        presentation.layoutInspector(visible: inspectorVisible)
        content.layoutSubtreeIfNeeded()
    }
    var divider: NSView? { firstDescendant(of: shell) { $0.accessibilityIdentifier() == "grid.sidebar.resize" } }
    func close() { window.close() }
}

@MainActor private func firstDescendant(of view: NSView, where match: (NSView) -> Bool) -> NSView? {
    for child in view.subviews {
        if match(child) { return child }
        if let found = firstDescendant(of: child, where: match) { return found }
    }
    return nil
}

@MainActor private func keyLoop(from canvas: NSView) -> [NSView] {
    var loop: [NSView] = [canvas]
    var next = canvas.nextKeyView
    while let view = next, view !== canvas, loop.count < 64 { loop.append(view); next = view.nextKeyView }
    return loop
}

@Test(arguments: [NSSize(width: 800, height: 680), NSSize(width: 960, height: 800),
                  NSSize(width: 1280, height: 800), NSSize(width: 1600, height: 680)])
@MainActor func i444ViewerFramesPartitionContentWidth(size: NSSize) {
    for sidebarWidth in [160.0, 200, 240, 320] {
        for inspector in [false, true] {
            let scene = Sidebar444Scene(size: size, sidebarWidth: sidebarWidth, inspector: inspector)
            defer { scene.close() }
            let label = "\(size) w \(sidebarWidth) inspector \(inspector)"
            let w = CGFloat(sidebarWidth), contentWidth = scene.width - scene.panel
            #expect(!scene.shell.isHidden, "\(label)")
            #expect(scene.shell.frame == NSRect(x: 0, y: 0, width: w, height: size.height - 28), "\(label) shell \(scene.shell.frame)")
            let expected = NSRect(x: w, y: 0, width: contentWidth - w, height: size.height)
            #expect(scene.canvas.frame == expected, "\(label) canvas \(scene.canvas.frame)")
            #expect(scene.chrome.frame == expected && scene.state.frame == expected, "\(label)")
            #expect(scene.shell.frame.width + scene.canvas.frame.width + scene.panel == scene.width, "\(label)")
            if scene.panel > 0 { #expect(scene.inspector.frame.minX == scene.canvas.frame.maxX, "\(label)") }
        }
    }
}

@Test @MainActor func i444ViewerModeHidesGridOnlyParts() {
    let scene = Sidebar444Scene()
    defer { scene.close() }
    #expect(scene.shell.mode == .viewerSidebar)
    #expect(!scene.shell.isGridSurface)
    #expect(scene.shell.footer.isHidden && scene.shell.footer.isAccessibilityHidden())
    #expect(scene.shell.mainContent.isHidden && scene.shell.mainContent.isAccessibilityHidden())
    #expect(!scene.shell.isDisplayPanelOpen)
    #expect(!scene.shell.sidebar.isHidden)
    #expect(scene.shell.sidebar.frame.minY == 0 && scene.shell.sidebar.frame.height == scene.shell.bounds.height)
    #expect(scene.shell.sidebar.frame.width == 196)
}

@Test @MainActor func i444UnavailableOrHiddenSidebarKeepsFullWidthViewer() {
    for (available, visible) in [(false, true), (true, false)] {
        let scene = Sidebar444Scene(visible: visible, available: available)
        defer { scene.close() }
        #expect(scene.shell.isHidden, "available \(available) visible \(visible)")
        #expect(scene.canvas.frame == scene.content.bounds && scene.chrome.frame == scene.content.bounds
                && scene.state.frame == scene.content.bounds, "available \(available) visible \(visible)")
    }
}

@Test(arguments: [160.0, 320.0], [false, true])
@MainActor func i444SidebarToggleRoundTripIsIdentity(sidebarWidth: Double, inspector: Bool) {
    let scene = Sidebar444Scene(sidebarWidth: sidebarWidth, inspector: inspector)
    defer { scene.close() }
    func snapshot() -> [String] {
        [scene.shell, scene.canvas, scene.chrome, scene.state, scene.inspector].map {
            "\($0.frame) \($0.isHidden) \($0.isAccessibilityHidden())"
        }
    }
    let shown = snapshot()
    var firstHidden: [String]?
    for round in 1...3 {
        scene.toggle()
        #expect(scene.shell.isHidden && !scene.session.isViewerSidebarShown, "round \(round)")
        #expect(scene.store.value.gridSidebarVisible, "the grid's preference never changes (round \(round))")
        let full = NSRect(x: 0, y: 0, width: scene.width - scene.panel, height: scene.content.bounds.height)
        #expect(scene.canvas.frame == full && scene.chrome.frame == full && scene.state.frame == full, "round \(round)")
        if let firstHidden { #expect(snapshot() == firstHidden, "round \(round)") } else { firstHidden = snapshot() }
        scene.toggle()
        #expect(snapshot() == shown, "round \(round)")
        #expect(scene.session.isViewerSidebarShown && scene.store.value.gridSidebarVisible, "round \(round)")
    }
}

@Test(arguments: [true, false], [false, true])
@MainActor func i444ViewerGridRoundTripRestoresShellGeometry(visible: Bool, inspector: Bool) {
    let scene = Sidebar444Scene(visible: visible, inspector: inspector)
    defer { scene.close() }
    func gridSnapshot() -> [String] {
        scene.presentation.showGrid(reading: false)
        scene.presentation.layoutInspector(visible: inspector)
        scene.content.layoutSubtreeIfNeeded()
        let shell = scene.shell
        return ["\(shell.frame)", "\(shell.mainFrame)", "\(shell.sidebar.frame) \(shell.sidebar.isHidden)",
                "\(shell.footer.frame) \(shell.footer.isHidden)", "\(shell.mainContent.frame) \(shell.mainContent.isHidden)",
                "\(shell.isGridSurface)", "\(scene.store.value.gridSidebarWidth) \(scene.store.value.gridSidebarVisible)"]
    }
    let first = gridSnapshot()
    #expect(scene.shell.isGridSurface && scene.shell.mode == .grid)
    scene.presentation.showViewer()
    scene.presentation.layoutInspector(visible: inspector)
    #expect(gridSnapshot() == first)
    #expect(scene.shell.isGridSurface)
}

@Test(arguments: [false, true])
@MainActor func i444CompactWidthsKeepPodsClearOfSidebar(inspector: Bool) {
    var rows: [(NSSize, Double)] = stride(from: 160.0, through: 320, by: 8).map { (NSSize(width: 800, height: 680), $0) }
    rows += [(NSSize(width: 238, height: 168), 160), (NSSize(width: 238, height: 168), 320)]
    for (size, sidebarWidth) in rows {
        let scene = Sidebar444Scene(size: size, sidebarWidth: sidebarWidth, inspector: inspector)
        defer { scene.close() }
        let label = "\(size) w \(sidebarWidth) inspector \(inspector)"
        let contentWidth = scene.width - scene.panel
        #expect(scene.shell.frame.width == min(CGFloat(sidebarWidth), contentWidth), "\(label)")
        #expect(scene.canvas.frame.width >= 0 && scene.canvas.frame.width.isFinite, "\(label)")
        #expect(scene.chrome.frame.width == scene.canvas.frame.width, "\(label)")
        guard size.width >= 800 else { continue }
        let groups = scene.chrome.groups.map { $0.convert($0.bounds, to: nil) }
        for group in groups { #expect(group.minX >= scene.shell.frame.maxX, "\(label) group \(group)") }
        for i in groups.indices { for j in groups.indices where i < j {
            let overlap = groups[i].intersection(groups[j])
            #expect(overlap.isNull || overlap.width * overlap.height == 0, "\(label) \(i)/\(j)")
        } }
    }
}

@Test @MainActor func i444HitTestRightOfSidebarNeverReturnsShell() {
    let scene = Sidebar444Scene(sidebarWidth: 240)
    defer { scene.close() }
    let w: CGFloat = 240, height = scene.content.bounds.height
    var xs: [CGFloat] = [w, w + 1, 640, 1279]
    xs += (0..<20).map { w + CGFloat($0) * (1279 - w) / 19 }
    var ys: [CGFloat] = [1, 400, height - 29]
    ys += (0..<10).map { 1 + CGFloat($0) * (height - 30) / 9 }
    for x in xs { for y in ys {
        let hit = scene.content.hitTest(NSPoint(x: x, y: y))
        #expect(hit !== scene.shell && hit?.isDescendant(of: scene.shell) != true, "(\(x), \(y)) hit \(String(describing: hit))")
    } }
    if let row = scene.shell.folderTree.rows.first {
        let centre = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: scene.content)
        #expect(scene.content.hitTest(centre)?.isDescendant(of: scene.shell) == true)
    } else {
        Issue.record("the seeded folder tree has no rows")
    }
}

@MainActor private func sidebar444Image(_ size: CGSize) throws -> DecodedImage {
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    return DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: size)
}

@Test @MainActor func i444CanvasWidthChangeRefitsImage() throws {
    let scene = Sidebar444Scene(sidebarWidth: 240) { CanvasView(frame: .zero, session: $0) }
    defer { scene.close() }
    let canvas = try #require(scene.canvas as? CanvasView)
    // The canvas asks for detail sized by its viewport and fitted zoom: 3000×2000 is width-limited beside the
    // sidebar (1040 pt) and height-limited without it (1280 pt), so a refit asks for more pixels, then fewer again.
    var requests: [Int] = []
    canvas.onResolutionNeeded = { requests.append($0) }
    canvas.install(try sidebar444Image(CGSize(width: 3000, height: 2000)))
    #expect(scene.session.zoomMode == .fit)
    #expect(canvas.frame == NSRect(x: 240, y: 0, width: 1040, height: 800))
    canvas.synchronizeViewport()  // install fits without asking; a viewport sync asks for the fitted detail
    let narrow = try #require(requests.last)
    scene.toggle()
    #expect(canvas.frame == NSRect(x: 0, y: 0, width: 1280, height: 800))
    #expect(scene.session.zoomMode == .fit, "a sidebar change keeps fit, so the canvas refits on its new size")
    let wide = try #require(requests.last)
    #expect(wide > narrow, "the wider canvas fits the image larger: \(narrow) → \(wide)")
    scene.toggle()
    #expect(canvas.frame == NSRect(x: 240, y: 0, width: 1040, height: 800) && scene.session.zoomMode == .fit)
    #expect(requests.last == narrow, "showing the sidebar again refits to the first size")
}

@Test @MainActor func i444DividerAdjustInViewerClampsPersistsAndRelaysOut() {
    let scene = Sidebar444Scene(sidebarWidth: 196)
    defer { scene.close() }
    for (requested, stored) in [(100.0, 160.0), (160, 160), (241, 241), (320, 320), (500, 320), (.infinity, 320)] {
        scene.shell.resizeSidebar(to: CGFloat(requested))
        scene.content.layoutSubtreeIfNeeded()
        #expect(scene.store.value.gridSidebarWidth == stored, "request \(requested)")
        #expect(scene.canvas.frame.minX == CGFloat(stored), "request \(requested) canvas \(scene.canvas.frame)")
        #expect(scene.shell.frame.width == CGFloat(stored), "request \(requested)")
        #expect(scene.state.frame == scene.canvas.frame, "request \(requested)")
    }
}

@Test @MainActor func i444IsGridSurfaceTruthTableAndGridOnlyHooksInert() {
    let scene = Sidebar444Scene()
    defer { scene.close() }
    let viewerState = scene.state.frame
    scene.presentation.resumeReadingFooter(true)
    #expect(scene.shell.footer.isHidden, "a viewer-entry read keeps the footer hidden")
    scene.shell.resizeSidebar(to: 250)
    scene.content.layoutSubtreeIfNeeded()
    #expect(scene.state.frame == NSRect(x: 250, y: 0, width: 1030, height: 800), "state follows the canvas, not mainFrame")
    #expect(viewerState != scene.state.frame)
    for mode in [GridShellView.Mode.grid, .viewerSidebar] {
        for hidden in [false, true] {
            scene.shell.setMode(mode)
            scene.shell.isHidden = hidden
            #expect(scene.shell.isGridSurface == (!hidden && mode == .grid), "\(mode) hidden \(hidden)")
        }
    }
}

@Test @MainActor func i444ViewerKeyLoopVisitsSidebarAfterToolsOnlyWhenShown() throws {
    let scene = Sidebar444Scene()
    defer { scene.close() }
    let divider = try #require(scene.divider)
    let tools = scene.chrome.tools.filter(\.acceptsFirstResponder)
    let rows = scene.shell.folderTree.rows
    try #require(rows.count == 4, "current folder plus 3 children")
    let expected: [NSView] = [scene.canvas] + scene.state.buttons.filter(\.acceptsFirstResponder) + tools + [divider] + rows
    let loop = keyLoop(from: scene.canvas)
    #expect(loop.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init), "\(loop.map { $0.accessibilityIdentifier() })")
    // Reverse traversal: Shift-Tab from the canvas enters the last sidebar row, then walks back.
    #expect(ViewerStateFocus.move(reverse: true, entering: true, state: scene.state, chrome: scene.chrome))
    #expect(scene.window.firstResponder === rows.last)
    scene.toggle()
    scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
    let hiddenLoop = keyLoop(from: scene.canvas)
    #expect(!hiddenLoop.contains { $0.isDescendant(of: scene.shell) })
    #expect(scene.shell.isHidden)
    #expect(ViewerStateFocus.move(reverse: true, entering: true, state: scene.state, chrome: scene.chrome))
    #expect((scene.window.firstResponder as? NSView)?.isDescendant(of: scene.shell) != true)
}

@Test @MainActor func i444HidingSidebarWithFocusedRowFocusesCanvas() throws {
    for useDivider in [false, true] {
        let scene = Sidebar444Scene()
        defer { scene.close() }
        let rows = scene.shell.folderTree.rows
        try #require(rows.count > 1)
        let target: NSView = useDivider ? try #require(scene.divider) : rows[1]
        #expect(scene.window.makeFirstResponder(target))
        scene.session.updateFocus(.tools)
        scene.toggle()
        #expect(scene.window.firstResponder === scene.canvas, "divider \(useDivider)")
        #expect(scene.session.inspectorFocus.focus == .canvas, "divider \(useDivider)")
        #expect(!scene.session.chrome.locks.contains(.keyboardFocus), "divider \(useDivider)")
    }
}

/// Hiding the first responder hands focus to its next valid key view; with the sidebar shown beside the viewer that
/// would be the sidebar, not the canvas, so Esc and the arrows would stop reaching the viewer (#444 App regression).
enum Sidebar444FocusPlace: Sendable, CaseIterable { case grid, main, footer }

@Test(arguments: [true, false], Sidebar444FocusPlace.allCases)
@MainActor func i444EnteringViewerMovesGridFocusToCanvas(sidebarShown: Bool, place: Sidebar444FocusPlace) {
    let scene = Sidebar444Scene(visible: sidebarShown)
    defer { scene.close() }
    scene.presentation.showGrid(reading: false)
    scene.content.layoutSubtreeIfNeeded()
    let focused = Sidebar444Canvas(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    switch place {
    case .grid:
        scene.shell.mainContent.addSubview(scene.grid)
        scene.grid.isHidden = false
        scene.grid.addSubview(focused)
    case .main: scene.shell.mainContent.addSubview(focused)
    case .footer: scene.shell.footer.addSubview(focused)  // a footer control (sidebar toggle, search, sort)
    }
    focused.nextKeyView = scene.divider  // the grid's key loop runs on into the sidebar, as in the App
    #expect(scene.window.makeFirstResponder(focused))
    // The App's window turns any responder change into session focus and then refuses the canvas unless that focus
    // is the canvas, so focus must never pass through the sidebar on the way (AppKit's hide hand-off would do that).
    scene.window.visited = []
    scene.presentation.showViewer()
    let visited = scene.window.visited
    #expect(scene.window.firstResponder === scene.canvas, "sidebar \(sidebarShown) \(place)")
    #expect(!visited.contains { ($0 as? NSView)?.isDescendant(of: scene.shell) == true },
            "focus passed through \(visited.map { type(of: $0) })")
    let row = scene.shell.viewerSidebarKeyViews.last
    if sidebarShown, let row {
        #expect(scene.window.makeFirstResponder(row))
        scene.presentation.showViewer()
        #expect(scene.window.firstResponder === row, "focus already beside the viewer stays where it is")
    }
}

/// Returning to the grid must not lay the grid out inside the viewer's narrow sidebar frame: a zero-width grid traps
/// in NSCollectionViewFlowLayout (itemSize.width > 0), seen via 返回网格 in the App.
@Test(arguments: [NSSize(width: 800, height: 680), NSSize(width: 1280, height: 800)], [true, false])
@MainActor func i444ReturningToGridNeverLaysOutANarrowGrid(size: NSSize, sidebarShown: Bool) {
    let scene = Sidebar444Scene(size: size, visible: sidebarShown)
    defer { scene.close() }
    let main = scene.shell.mainContent
    main.postsFrameChangedNotifications = true
    var widths: [CGFloat] = []
    let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: main, queue: nil) { _ in
        MainActor.assumeIsolated { widths.append(main.frame.width) }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    scene.presentation.showGrid(reading: false)
    scene.content.layoutSubtreeIfNeeded()
    let final = main.frame.width
    #expect(final > 300, "the grid spans the content beside the sidebar")
    #expect(widths.allSatisfy { $0 == final }, "intermediate grid widths \(widths), final \(final)")
}

/// The folder tree reloads its rows while the viewer shows it (counts and children arrive late); the viewer's loop
/// canvas → tools → sidebar → canvas must take in the new rows instead of keeping the replaced ones.
@Test(arguments: [2, 5])
@MainActor func i444SidebarTreeReloadInViewerKeepsTheKeyLoop(children: Int) {
    let scene = Sidebar444Scene()
    defer { scene.close() }
    scene.shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/photos"), count: 3), parent: nil,
        children: (0..<children).map { GridSidebarFolder(url: URL(fileURLWithPath: "/photos/n\($0)"), count: 1) })
    scene.content.layoutSubtreeIfNeeded()
    let rows = scene.shell.viewerSidebarKeyViews
    #expect(rows.count == children + 2, "divider, the current folder and each child")
    let loop = keyLoop(from: scene.canvas)
    #expect(Array(loop.suffix(rows.count)).elementsEqual(rows, by: ===), "the loop ends with the reloaded sidebar rows")
    #expect(rows.last?.nextKeyView === scene.canvas, "the last row wraps to the canvas")
}

/// The sidebar leaving the viewer some other way than ⌃⌘S (the preview stops being a folder preview) while a row
/// holds focus hands focus to the canvas, not to the hidden sidebar.
@Test @MainActor func i444SidebarBecomingUnavailableWithRowFocusHandsFocusToCanvas() throws {
    let scene = Sidebar444Scene()
    defer { scene.close() }
    let row = try #require(scene.shell.viewerSidebarKeyViews.last)
    #expect(scene.window.makeFirstResponder(row))
    scene.presentation.viewerSidebarAvailable = false
    scene.presentation.layoutInspector(visible: false)
    #expect(scene.shell.isHidden)
    #expect(scene.window.firstResponder === scene.canvas)
    #expect(scene.session.inspectorFocus.focus == .canvas)
    #expect(scene.canvas.frame == scene.content.bounds, "the viewer takes the full width again")
}

/// A hidden grid shell outside the viewer (the Home) leaves the state surface over the whole content.
@Test @MainActor func i444GridLayoutWithHiddenShellGivesStateTheContent() {
    let scene = Sidebar444Scene()
    defer { scene.close() }
    scene.presentation.showGrid(reading: false)
    scene.shell.isHidden = true
    scene.presentation.layoutInspector(visible: false)
    #expect(scene.state.frame == scene.content.bounds)
    #expect(scene.canvas.frame == scene.content.bounds)
}

/// Owner decision 2026-11-04 (#444): the viewer's sidebar is independent of the grid's and starts hidden on entry;
/// toggling it in the viewer never changes the grid's, and returning to the grid shows the grid's sidebar as it was.
@Test(arguments: [true, false])
@MainActor func i444ViewerSidebarStartsHiddenAndLeavesTheGridsAlone(gridVisible: Bool) {
    let scene = Sidebar444Scene(visible: false, gridVisible: gridVisible)
    defer { scene.close() }
    let prefs = scene.store.value
    #expect(scene.shell.isHidden && scene.canvas.frame == scene.content.bounds, "entry from the grid starts hidden")
    scene.toggle()
    #expect(!scene.shell.isHidden && scene.canvas.frame.minX == 196, "显示侧栏 shows it beside the image")
    #expect(scene.store.value == prefs, "the grid's sidebar preference is untouched")
    scene.toggle()
    #expect(scene.shell.isHidden && scene.store.value == prefs)
    scene.toggle()
    scene.session.perform(intent: .returnToGrid)
    scene.presentation.showGrid(reading: false)
    scene.presentation.layoutInspector(visible: false)
    scene.content.layoutSubtreeIfNeeded()
    #expect(scene.shell.mode == .grid && !scene.shell.isHidden)
    #expect(scene.shell.mainFrame.minX == (gridVisible ? 196 : 0), "the grid's sidebar is exactly as it was")
    CommandRouter().route(.preview, from: .key, to: scene.session)  // the grid keeps the origin's selection
    #expect(scene.session.mode == .viewing)
    scene.presentation.showViewer()
    scene.presentation.layoutInspector(visible: false)
    #expect(scene.shell.isHidden && scene.canvas.frame == scene.content.bounds, "the next entry starts hidden again")
}
