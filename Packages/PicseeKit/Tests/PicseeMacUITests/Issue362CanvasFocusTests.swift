import AppKit
import SwiftUI
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

private final class Issue362StageReference: NSView {
    let showsRing: Bool
    init(frame: NSRect, showsRing: Bool) {
        self.showsRing = showsRing
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            DesignColor.canvasBackground.nsColor.setFill()
            bounds.fill()
            if showsRing {
                DesignColor.focusRing.nsColor.setStroke()
                let ring = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }
}

private final class Issue362Window: NSWindow {
    private var injectedEvent: NSEvent?
    var onEscape: (() -> Void)?
    override var currentEvent: NSEvent? { injectedEvent }
    override func sendEvent(_ event: NSEvent) {
        injectedEvent = event
        defer { injectedEvent = nil }
        if event.type == .keyDown, event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        guard event.type == .keyDown, event.keyCode == 48 else {
            super.sendEvent(event)
            return
        }
        guard let current = firstResponder as? NSView else { return }
        if event.modifierFlags.contains(.shift) {
            selectKeyView(preceding: current)
        } else {
            selectKeyView(following: current)
        }
    }
}

private final class Issue362Canvas: CanvasView {
    var displayScheduled = false
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { displayScheduled = true }
            super.needsDisplay = newValue
        }
    }
}

@MainActor private func issue362Bitmap(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@MainActor private func issue362ExpectReference(_ canvas: CanvasView, ring: Bool) throws {
    let reference = Issue362StageReference(frame: canvas.bounds, showsRing: ring)
    reference.appearance = canvas.appearance
    let actual = try issue362Bitmap(canvas).tiffRepresentation
    let expected = try issue362Bitmap(reference).tiffRepresentation
    #expect(actual == expected, "stage ring shown=\(ring), appearance=\(canvas.appearance?.name ?? .aqua)")
}

@MainActor private func issue362Key(_ window: NSWindow, shift: Bool) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
}

@MainActor private func issue362Image() throws -> DecodedImage {
    let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    return DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 800, height: 400))
}

@Test @MainActor func issue362StageRingAppearsOnlyAfterKeyboardNavigation() throws {
    _ = NSApplication.shared
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let frame = NSRect(x: 0, y: 0, width: 432, height: 232)
        let content = NSView(frame: frame)
        let canvas = Issue362Canvas(frame: frame, session: ViewerSession())
        let button = NSButton(frame: NSRect(x: 360, y: 10, width: 50, height: 24))
        content.addSubview(canvas)
        content.addSubview(button)
        canvas.nextKeyView = button
        button.nextKeyView = canvas
        let window = Issue362Window(contentRect: frame.offsetBy(dx: -20000, dy: -20000),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        canvas.appearance = try #require(NSAppearance(named: name))
        canvas.focusRingType = .exterior
        window.orderFrontRegardless()
        defer { window.close() }

        #expect(window.makeFirstResponder(canvas))
        #expect(canvas.focusRingType == .none)
        try issue362ExpectReference(canvas, ring: false)

        #expect(window.makeFirstResponder(button))
        window.sendEvent(try issue362Key(window, shift: false))
        #expect(window.firstResponder === canvas)
        try issue362ExpectReference(canvas, ring: true)
        canvas.displayIfNeeded()
        #expect(!canvas.needsDisplay)
        canvas.displayScheduled = false

        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: canvas.convert(CGPoint(x: 100, y: 100), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: mouse)
        #expect(canvas.focusRingType == .none)
        #expect(canvas.displayScheduled, "clicking a visible ring must schedule its removal")
        canvas.displayIfNeeded()
        try issue362ExpectReference(canvas, ring: false)

        #expect(window.makeFirstResponder(button))
        window.sendEvent(try issue362Key(window, shift: true))
        #expect(window.firstResponder === canvas)
        try issue362ExpectReference(canvas, ring: true)

        canvas.beginOpening()
        #expect(canvas.focusRingType == .none)
        try issue362ExpectReference(canvas, ring: false)
        canvas.install(try issue362Image())
        let openedWithoutRing = try issue362Bitmap(canvas).tiffRepresentation

        #expect(window.makeFirstResponder(button))
        window.sendEvent(try issue362Key(window, shift: false))
        #expect(try issue362Bitmap(canvas).tiffRepresentation != openedWithoutRing)
        #expect(window.makeFirstResponder(button))
        #expect(window.makeFirstResponder(canvas))
        #expect(canvas.focusRingType == .none)
        #expect(try issue362Bitmap(canvas).tiffRepresentation == openedWithoutRing)
    }
}

@MainActor private final class Issue362Host: ViewerSessionHost {
    weak var canvas: CanvasView?
    var hasImage: Bool { canvas?.hasImage == true }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {
        if focus == .canvas { _ = canvas?.window?.makeFirstResponder(canvas) }
    }
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() {}
}

private struct Issue362InspectorReader: InspectorMetadataReading {
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata { .init() }
}

@MainActor private func issue362KeyCode(_ window: NSWindow, keyCode: UInt16) throws -> NSEvent {
    let characters: [UInt16: String] = [53: "\u{1b}", 123: "\u{F702}", 124: "\u{F703}"]
    let text = try #require(characters[keyCode])
    return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
        isARepeat: false, keyCode: keyCode))
}

@Test @MainActor func issue362KeyboardRingAfterEscapeFromTool() throws {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 432, height: 232)
    let session = ViewerSession()
    let canvas = CanvasView(frame: frame, session: session)
    let tool = ChromeToolView(frame: NSRect(x: 180, y: 190, width: 40, height: 32),
                              session: session, command: .open)
    let host = Issue362Host()
    host.canvas = canvas
    session.host = host
    let content = NSView(frame: frame)
    content.addSubview(canvas)
    content.addSubview(tool)
    let window = Issue362Window(contentRect: frame.offsetBy(dx: -20000, dy: -20000),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.orderFrontRegardless()
    defer { window.close() }

    #expect(window.makeFirstResponder(tool))
    window.sendEvent(try issue362KeyCode(window, keyCode: 53))
    #expect(window.firstResponder === canvas)
    try issue362ExpectReference(canvas, ring: true)
}

@Test @MainActor func issue362KeyboardRingAfterEscapeClosesInspector() throws {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 652, height: 500)
    let session = ViewerSession()
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 432, height: 500), session: session)
    let window = Issue362Window(contentRect: frame.offsetBy(dx: -20000, dy: -20000),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let model = InspectorModel(reader: Issue362InspectorReader())
    let host = Issue362Host()
    host.canvas = canvas
    session.host = host
    var updates: [FocusContext] = []
    // Same body as the App's restore: focus only; the ring comes from the key press.
    let panel = NSHostingView(rootView: InspectorPanel(model: model, session: session,
        close: {}, restoreCanvasFocus: { _ = window.makeFirstResponder(canvas) },
        updateFocus: { updates.append($0); session.updateFocus($0) }))
    panel.frame = NSRect(x: 432, y: 0, width: 220, height: 500)
    let content = NSView(frame: frame)
    content.addSubview(canvas)
    content.addSubview(panel)
    window.contentView = content
    window.onEscape = {
        _ = CommandRouter().route(.escape, from: .key, to: session)
        panel.layoutSubtreeIfNeeded()
    }
    window.orderFrontRegardless()
    defer { window.close() }

    session.setInspectorVisible(true)
    panel.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let closeButton = try #require(descendants(panel).compactMap { $0 as? NSButton }
        .first { $0.accessibilityIdentifier() == "inspector.close" })
    #expect(window.makeFirstResponder(closeButton))
    #expect(updates.contains(.panel))
    #expect(window.firstResponder !== canvas)
    // Esc → session → host.applyFocus(.canvas) inside the key press, as in the App.
    window.sendEvent(try issue362KeyCode(window, keyCode: 53))
    for _ in 0..<10 {
        panel.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    #expect(session.inspectorFocus.focus == .canvas)
    #expect(window.firstResponder === canvas)
    try issue362ExpectReference(canvas, ring: true)
}

@Test @MainActor func issue362KeyboardRingSurvivesArrowNavigation() throws {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 432, height: 232)
    let canvas = CanvasView(frame: frame, session: ViewerSession())
    let button = NSButton(frame: NSRect(x: 360, y: 10, width: 50, height: 24))
    let content = NSView(frame: frame)
    content.addSubview(canvas)
    content.addSubview(button)
    canvas.nextKeyView = button
    button.nextKeyView = canvas
    let window = Issue362Window(contentRect: frame.offsetBy(dx: -20000, dy: -20000),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.orderFrontRegardless()
    defer { window.close() }

    canvas.onCommand = { id in
        guard id == .previous || id == .next else { return false }
        canvas.beginOpening()
        return true
    }
    #expect(window.makeFirstResponder(button))
    window.sendEvent(try issue362Key(window, shift: false))
    #expect(window.firstResponder === canvas)
    try issue362ExpectReference(canvas, ring: true)

    for keyCode in [UInt16(123), UInt16(124)] {
        window.sendEvent(try issue362KeyCode(window, keyCode: keyCode))
        try issue362ExpectReference(canvas, ring: true)
        // The App tests read this state; it must agree with the rendered ring.
        #expect(canvas.isShowingKeyboardFocusRing)
    }
}

@Test @MainActor func issue362HandledArrowWithoutOpeningLeavesNoRingForLaterOpening() throws {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 432, height: 232)
    let canvas = CanvasView(frame: frame, session: ViewerSession())
    let button = NSButton(frame: NSRect(x: 360, y: 10, width: 50, height: 24))
    let content = NSView(frame: frame)
    content.addSubview(canvas)
    content.addSubview(button)
    canvas.nextKeyView = button
    button.nextKeyView = canvas
    let window = Issue362Window(contentRect: frame.offsetBy(dx: -20000, dy: -20000),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.orderFrontRegardless()
    defer { window.close() }

    // The end of a preview set accepts ←/→ and opens nothing.
    canvas.onCommand = { id in id == .previous || id == .next }
    #expect(window.makeFirstResponder(button))
    window.sendEvent(try issue362Key(window, shift: false))
    try issue362ExpectReference(canvas, ring: true)
    window.sendEvent(try issue362KeyCode(window, keyCode: 124))
    try issue362ExpectReference(canvas, ring: true)

    // A later opening outside any key event (Finder, toolbar, programmatic) never keeps the ring.
    canvas.beginOpening()
    try issue362ExpectReference(canvas, ring: false)
}
