import AppKit
import Observation
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor func issue527Find(_ view: NSView?, matching: (NSView) -> Bool) -> NSView? {
    guard let view else { return nil }
    if matching(view) { return view }
    for child in view.subviews {
        if let found = issue527Find(child, matching: matching) { return found }
    }
    return nil
}

/// Real native window and oversized image with a rendered landmark, shared by #527 cases.
@MainActor final class Issue527Scene {
    let base: URL
    let folder: URL
    let controller: CanvasWindowController
    let window: CommandWindow
    var canvas: CanvasView { issue521Find(CanvasView.self, in: window.contentView)! }
    var overlay: ViewerChromeOverlay { issue521Find(ViewerChromeOverlay.self, in: window.contentView)! }
    var eventNumber = 0

    init() throws {
        _ = NSApplication.shared
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("issue527-\(UUID().uuidString)")
        folder = base.appendingPathComponent("photos")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 1160, y: 760, width: 80, height: 80))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("marker.png"))
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue527")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: Issue521Motion()))
        window = try #require(controller.window as? CommandWindow)
        window.setContentSize(NSSize(width: 1000, height: 650))
    }

    func open(keyWindowTimeout: Duration) async throws {
        controller.showWindow(nil)
        try makeFixtureWindowKey(window, timeout: keyWindowTimeout)
        try #require(window.isKeyWindow)
        controller.openGrantedFolder(folder)
        try await wait { self.controller.gridSearchAvailable }
        try #require(controller.route(.preview, from: .key))
        try await wait {
            self.controller.session.mode == .viewing && self.controller.hasImage &&
                self.controller.session.imageLoader.phase == .settled
        }
        try #require(controller.route(.actualPixels, from: .key))
        try await wait { self.controller.session.imageLoader.phase == .settled }
        try #require(2400 / window.backingScaleFactor > canvas.bounds.width + 100)
        try #require(1600 / window.backingScaleFactor > canvas.bounds.height + 100)
    }

    func close() {
        window.close()
        try? FileManager.default.removeItem(at: base)
    }
    func layout() { window.contentView?.layoutSubtreeIfNeeded(); window.update() }
    func wait(_ condition: () -> Bool) async throws {
        try await MadoAppTests.waitUntil(between: { self.layout() }, condition)
    }
    func focusTool() throws -> ChromeToolView {
        let tool = try #require(overlay.tools.first { $0.accessibilityIdentifier() == "chrome.returnToGrid.button" })
        try #require(window.makeFirstResponder(tool))
        try #require(window.firstResponder === tool && controller.session.inspectorFocus.focus == .tools)
        return tool
    }
    func mouse(_ type: NSEvent.EventType, at location: CGPoint) throws {
        eventNumber += 1
        let event = try #require(NSEvent.mouseEvent(with: type, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
    }
    func hit(at point: CGPoint) -> NSView? {
        guard let content = window.contentView, let parent = content.superview else { return nil }
        return content.hitTest(parent.convert(point, from: nil))
    }
}

@MainActor private final class Issue527FocusHistory {
    var entries: [(NSResponder?, FocusContext)] = []
    var sessionMutated = false
    func sample(_ scene: Issue527Scene) {
        entries.append((scene.window.firstResponder, scene.controller.session.inspectorFocus.focus))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] != "1"),
      .timeLimit(.minutes(3))) @MainActor
func issue527NonCanvasPressesPassInIsolatedProcess() async throws {
    try await issue521RunNativeTest(filter: "issue527NonCanvasPressPreservesFocusAndImage\\b",
        summary: "Test issue527NonCanvasPressPreservesFocusAndImage(target:) with 4 test cases passed")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] == "1"),
      .timeLimit(.minutes(3)), arguments: ["inspector", "sidebar", "chromeGap", "overlay"]) @MainActor
func issue527NonCanvasPressPreservesFocusAndImage(target: String) async throws {
    let scene = try Issue527Scene()
    defer { scene.close() }
    // Reserve one twelfth of this child's three-minute limit for key acquisition.
    try await scene.open(keyWindowTimeout: .seconds(180) / 12)
    let content = try #require(scene.window.contentView)
    var addedOverlay: NSView?
    defer { addedOverlay?.removeFromSuperview() }
    let surface: NSView
    let localPoint: CGPoint
    switch target {
    case "inspector":
        try #require(scene.controller.route(.inspector, from: .key))
        scene.layout()
        let close = try #require(issue527Find(content) { $0.accessibilityIdentifier() == "inspector.close" })
        // The controller embeds the panel directly in a content-level hosting view.
        var panel = close
        while let parent = panel.superview, parent !== content { panel = parent }
        try #require(!panel.isHiddenOrHasHiddenAncestor && panel !== content)
        surface = panel
        localPoint = CGPoint(x: panel.bounds.midX, y: panel.bounds.midY)
    case "sidebar":
        scene.controller.session.perform(intent: .toggleSidebar)
        scene.layout()
        let shell = try #require(issue521Find(GridShellView.self, in: content))
        let sidebar = shell.sidebar
        try #require(scene.controller.session.isViewerSidebarShown && !sidebar.isHiddenOrHasHiddenAncestor)
        // Below the folder rows and above footer controls, in the native sidebar background.
        surface = sidebar
        localPoint = CGPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY)
    case "chromeGap":
        let group = try #require(scene.overlay.groups.first)
        let left = try #require(scene.overlay.tools.first)
        let right = scene.overlay.tools[1]
        try #require(left.superview === group && right.superview === group)
        surface = group
        localPoint = CGPoint(x: (left.frame.maxX + right.frame.minX) / 2, y: group.bounds.midY)
    default:
        let overlay = NSView(frame: scene.canvas.convert(
            CGRect(x: scene.canvas.bounds.midX - 80, y: scene.canvas.bounds.midY - 80, width: 160, height: 160), to: content))
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        addedOverlay = overlay
        surface = overlay
        localPoint = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
    }
    let tool = try scene.focusTool()
    scene.layout()
    // Resolve window coordinates only after focus has synchronized the visible chrome/layout.
    let point = surface.convert(localPoint, to: nil)
    let hit = try #require(scene.hit(at: point))
    print("[issue527-hit] target=\(target) point=\(point) class=\(String(reflecting: type(of: hit))) id=\(hit.accessibilityIdentifier() ?? "nil") expectedClass=\(String(reflecting: type(of: surface))) expectedID=\(surface.accessibilityIdentifier() ?? "nil") canvas=\(hit === scene.canvas) key=\(scene.window.isKeyWindow)")
    try #require(!surface.isHiddenOrHasHiddenAncestor)
    try #require(hit !== scene.canvas, "canvas hit requires design review, not a product fix")
    if target == "chromeGap" || target == "overlay" {
        try #require(hit === surface, "press must hit the intended background surface")
    } else {
        try #require(hit === surface || hit.isDescendant(of: surface))
        try #require(!(hit is NSControl) && !(hit is GridSidebarFolderButton), "press blank background")
    }
    let marker = try issue521Marker(scene.canvas)
    let imageURL = scene.controller.session.imageLoader.fileURL
    let history = Issue527FocusHistory()
    let original = scene.window.didChangeResponder
    scene.window.didChangeResponder = {
        original?()
        history.sample(scene)
    }
    defer { scene.window.didChangeResponder = original }
    // Observation invalidates synchronously even if a focus mutation is undone before the next
    // event boundary. One invalidation is enough to disprove the no-focus-change invariant.
    withObservationTracking {
        _ = scene.controller.session.inspectorFocus.focus
    } onChange: {
        MainActor.assumeIsolated { history.sessionMutated = true }
    }
    history.sample(scene)
    let end = CGPoint(x: point.x + 40, y: point.y + 30)
    for (type, location) in [(NSEvent.EventType.leftMouseDown, point), (.leftMouseDragged, end), (.leftMouseUp, end)] {
        try scene.mouse(type, at: location)
        history.sample(scene)
        #expect(scene.window.firstResponder === tool, "\(target) \(type): tool focus conserved")
        #expect(scene.controller.session.inspectorFocus.focus == .tools)
        #expect(try issue521Marker(scene.canvas) == marker, "\(target) \(type): no rendered pan")
    }
    #expect(!history.sessionMutated, "\(target): Session focus never changed, even transiently")
    #expect(history.entries.allSatisfy { $0.0 === tool && $0.1 == .tools },
        "\(target): every native responder transition and event boundary kept tool focus")
    #expect(scene.controller.session.mode == .viewing)
    #expect(scene.controller.session.imageLoader.fileURL == imageURL)
}
