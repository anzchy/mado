import AppKit
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
    override var currentEvent: NSEvent? { injectedEvent }
    override func sendEvent(_ event: NSEvent) {
        injectedEvent = event
        defer { injectedEvent = nil }
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
