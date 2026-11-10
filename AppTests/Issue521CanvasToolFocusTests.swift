import AppKit
@testable import Mado
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor final class Issue521Motion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor func issue521Find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    if let found = view as? T { return found }
    return view.subviews.lazy.compactMap { issue521Find(type, in: $0) }.first
}

/// Read the rendered image marker, rather than reflecting CanvasView's private transform.
@MainActor func issue521Marker(_ canvas: CanvasView) throws -> CGPoint {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.bounds.width), pixelsHigh: Int(canvas.bounds.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = canvas.bounds.size
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh
    // Both gestures leave the marker within this central region, away from chrome.
    for y in Int(canvas.bounds.midY - 150)..<Int(canvas.bounds.midY + 150) {
        for x in Int(canvas.bounds.midX - 150)..<Int(canvas.bounds.midX + 150) {
            let color = try #require(bitmap.colorAt(x: x, y: y))
            if color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1 {
                minX = min(minX, x); minY = min(minY, y)
            }
        }
    }
    try #require(minX < bitmap.pixelsWide && minY < bitmap.pixelsHigh, "image marker must be visible")
    return CGPoint(x: minX, y: minY)
}

@Test(.timeLimit(.minutes(3)), arguments: [0, 1, 2]) @MainActor
func issue521WindowDragPansFromCanvasAndTabFocusedTools(tabCount: Int) async throws {
    _ = NSApplication.shared
    _ = NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("issue521-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("photos")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    // Large at both 1x and 2x, with a red landmark centered on an otherwise black image.
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
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue521")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue521Motion()))
    let window = try #require(controller.window)
    defer { window.close() }
    window.setContentSize(NSSize(width: 800, height: 500))
    controller.showWindow(nil)
    // Reserve 15 s for key acquisition within this test's existing limit.
    try makeFixtureWindowKey(window, timeout: .seconds(180) / 12)
    try #require(window.isKeyWindow, "native mouse dispatch requires the fixture window to be key")
    controller.openGrantedFolder(folder)
    try await MadoHostedFocusTests.waitUntil(between: { window.update() }) { controller.gridSearchAvailable }
    try #require(controller.route(.preview, from: .key))
    try await MadoHostedFocusTests.waitUntil(between: { window.update() }) {
        controller.session.mode == .viewing && controller.hasImage && controller.session.imageLoader.phase == .settled
    }
    let canvas = try #require(issue521Find(CanvasView.self, in: window.contentView))
    let overlay = try #require(issue521Find(ViewerChromeOverlay.self, in: window.contentView))
    try #require(!canvas.isHiddenOrHasHiddenAncestor)
    try #require(window.firstResponder === canvas)
    try #require(controller.route(.actualPixels, from: .key))
    try await MadoHostedFocusTests.waitUntil(between: { window.update() }) { controller.session.imageLoader.phase == .settled }
    window.contentView?.layoutSubtreeIfNeeded()
    try #require(controller.session.zoomMode == .actualPixels)
    try #require(2400 / window.backingScaleFactor > canvas.bounds.width + 100)
    try #require(1600 / window.backingScaleFactor > canvas.bounds.height + 100)
    let imageURL = controller.session.imageLoader.fileURL
    let initial = try issue521Marker(canvas)
    let native = try #require(window as? CommandWindow)
    let originalResponderChange = native.didChangeResponder
    var canvasReceivedFocus = false
    native.didChangeResponder = { [weak window, weak canvas] in
        originalResponderChange?()
        if let window, let canvas, window.firstResponder === canvas { canvasReceivedFocus = true }
    }
    defer { native.didChangeResponder = originalResponderChange }
    var eventNumber = 0
    func focus() throws {
        try #require(window.firstResponder === canvas)
        for _ in 0..<tabCount {
            let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            window.sendEvent(tab)
        }
        if tabCount > 0 {
            let id = tabCount == 1 ? "chrome.sidebar.button" : "chrome.returnToGrid.button"
            let tool = try #require(overlay.tools.first { $0.accessibilityIdentifier() == id })
            try #require(window.firstResponder === tool, "Tab must focus the reported real tool")
        }
    }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws {
        eventNumber += 1
        let event = try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
    }
    let centre = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    for delta in [CGPoint(x: 40, y: 30), CGPoint(x: -40, y: -30)] {
        try focus()
        let before = try issue521Marker(canvas)
        let sidebar = controller.session.isViewerSidebarShown
        let end = CGPoint(x: centre.x + delta.x, y: centre.y + delta.y)
        if tabCount > 0 {
            let tool = try #require(window.firstResponder as? ChromeToolView)
            canvasReceivedFocus = false
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                eventNumber += 1
                let secondary = try #require(NSEvent.mouseEvent(with: type,
                    location: canvas.convert(centre, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: eventNumber, clickCount: 1,
                    pressure: type == .rightMouseUp ? 0 : 1))
                window.sendEvent(secondary)
                #expect(window.firstResponder === tool, "secondary canvas press keeps tool focus")
                #expect(controller.session.inspectorFocus.focus == .tools)
                #expect(!canvasReceivedFocus, "secondary press must never hand focus to canvas")
            }
            #expect(try issue521Marker(canvas) == before)
            #expect(controller.session.isViewerSidebarShown == sidebar)
            #expect(controller.session.mode == .viewing)
            #expect(controller.session.imageLoader.fileURL == imageURL)
        }
        try mouse(.leftMouseDown, centre)
        #expect(window.firstResponder === canvas, "primary canvas down takes focus before drag")
        #expect(controller.session.inspectorFocus.focus == .canvas)
        try mouse(.leftMouseDragged, end)
        try mouse(.leftMouseUp, end)
        let after = try issue521Marker(canvas)
        #expect(after.x - before.x == delta.x, "tabCount=\(tabCount): rendered horizontal pan")
        #expect(after.y - before.y == delta.y, "tabCount=\(tabCount): rendered vertical pan")
        #expect(window.firstResponder === canvas, "tabCount=\(tabCount): canvas takes focus")
        #expect(controller.session.isViewerSidebarShown == sidebar)
        #expect(controller.session.mode == .viewing)
        #expect(controller.session.imageLoader.fileURL == imageURL)
        // A failed handover should not prevent the reverse gesture from testing the same starting focus.
        if window.firstResponder !== canvas {
            controller.session.updateFocus(.canvas)
            _ = window.makeFirstResponder(canvas)
        }
    }
    #expect(try issue521Marker(canvas) == initial, "completed opposite drags restore the rendered placement")
    if tabCount > 0 {
        try focus()
        let tool = try #require(window.firstResponder as? ChromeToolView)
        let toolPoint = canvas.convert(CGPoint(x: tool.bounds.midX, y: tool.bounds.midY), from: tool)
        let sidebarBeforeClick = controller.session.isViewerSidebarShown
        canvasReceivedFocus = false
        try mouse(.leftMouseDown, toolPoint)
        #expect(window.firstResponder === tool, "tool primary down stays on the tool")
        #expect(controller.session.inspectorFocus.focus == .tools)
        #expect(!canvasReceivedFocus, "non-canvas press must not transiently steal canvas focus")
        #expect(controller.session.isViewerSidebarShown == sidebarBeforeClick)
        #expect(controller.session.mode == .viewing)
        try mouse(.leftMouseUp, toolPoint)
        if tabCount == 1 {
            #expect(controller.session.isViewerSidebarShown != sidebarBeforeClick)
        } else {
            #expect(controller.session.mode == .browsing)
        }
    }
}
