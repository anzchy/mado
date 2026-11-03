import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@MainActor private final class CanvasTestHost: ViewerSessionHost {
    weak var canvas: CanvasView?
    var hasImage: Bool { canvas?.hasImage == true }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { _ = canvas?.apply(command, from: entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { canvas?.apply(command, from: entry) }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
}

@MainActor private func canvasImage(_ size: CGSize) throws -> DecodedImage {
    let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    // Raw device components keep this synthetic fixture independent of CGColor's profile conversion.
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    return DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: size)
}

@MainActor private func canvasHost() -> (CanvasView, NSWindow, CanvasTestHost) {
    _ = NSApplication.shared
    let session = ViewerSession()
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 432, height: 232), session: session)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 432, height: 232),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    canvas.appearance = NSAppearance(named: .aqua)
    let host = CanvasTestHost()
    host.canvas = canvas
    session.host = host
    return (canvas, window, host)
}

@MainActor private func canvasBitmap(_ canvas: CanvasView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width),
        pixelsHigh: Int(canvas.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = canvas.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    return rep
}

@MainActor private func canvasRedBounds(_ canvas: CanvasView) throws -> CGRect {
    let rep = try canvasBitmap(canvas)
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let color = try #require(rep.colorAt(x: x, y: y))
            if color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0 else { return .zero }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@MainActor private func canvasMouse(_ canvas: CanvasView, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
}

@Test @MainActor func canvasViewFitDragResizeAndWindowGuard() throws {
    let (canvas, window, host) = canvasHost()
    defer { window.close(); withExtendedLifetime(host) {} }
    let retryGeneration = UUID()
    canvas.openingGeneration = { retryGeneration }
    canvas.beginOpening()
    let router = CommandRouter()
    var requests: [Int] = []
    canvas.onResolutionNeeded = { requests.append($0) }
    canvas.install(try canvasImage(.init(width: 800, height: 400)))
    #expect(try canvasRedBounds(canvas) == CGRect(x: 16, y: 16, width: 400, height: 200))
    #expect(!canvas.mouseDownCanMoveWindow)
    #expect(canvas.clipsToBounds)
    canvas.setFrameSize(.init(width: 232, height: 132))
    #expect(try canvasRedBounds(canvas) == CGRect(x: 16, y: 16, width: 200, height: 100))
    canvas.setFrameSize(.init(width: 432, height: 232))
    #expect(router.route(.actualPixels, from: .key, to: canvas.session))
    #expect(requests.contains(800))
    canvas.install(try canvasImage(.init(width: 80, height: 40)))
    let small = window.backingScaleFactor == 1 ? CGRect(x: 176, y: 96, width: 80, height: 40)
                                              : CGRect(x: 196, y: 106, width: 40, height: 20)
    #expect(try canvasRedBounds(canvas) == small)
    canvas.mouseDown(with: try canvasMouse(canvas, .leftMouseDown, .init(x: 216, y: 116)))
    canvas.mouseDragged(with: try canvasMouse(canvas, .leftMouseDragged, .init(x: 5000, y: 5000)))
    let far = window.backingScaleFactor == 1 ? CGRect(x: 352, y: 192, width: 80, height: 40)
                                            : CGRect(x: 392, y: 212, width: 40, height: 20)
    #expect(try canvasRedBounds(canvas) == far)
    canvas.mouseDragged(with: try canvasMouse(canvas, .leftMouseDragged, .init(x: -5000, y: -5000)))
    canvas.mouseUp(with: try canvasMouse(canvas, .leftMouseUp, .zero))
    #expect(try canvasRedBounds(canvas) == CGRect(x: 0, y: 0, width: small.width, height: small.height))
    #expect(router.route(.fit, from: .button, to: canvas.session))
    #expect(try canvasRedBounds(canvas) == small)
    canvas.magnify(by: log(2), at: .init(x: 216, y: 116))
    #expect(canvas.session.zoomMode == .custom(2))
    canvas.magnify(by: log(1000), at: .init(x: 216, y: 116))
    #expect(canvas.session.zoomMode == .custom(64))
    let before = try canvasRedBounds(canvas)
    canvas.beginOpening()
    #expect(!canvas.hasImage)
    canvas.install(try canvasImage(.init(width: 80, height: 40)))
    #expect(canvas.session.zoomMode == .custom(64))
    #expect(try canvasRedBounds(canvas) == before)
    canvas.install(try canvasImage(.init(width: 40, height: 80)))
    #expect(canvas.session.zoomMode == .fit)
}

@Test @MainActor func canvasViewThemesMessagesFocusAndPublicInput() throws {
    let (canvas, window, host) = canvasHost()
    defer { window.close(); withExtendedLifetime(host) {} }
    #expect(CanvasView(coder: NSCoder()) == nil)
    #expect(canvas.isFlipped && canvas.acceptsFirstResponder)
    #expect(canvas.accessibilityRole() == .image)
    #expect(canvas.accessibilityLabel() == "Image")
    #expect(canvas.accessibilityIdentifier() == "viewer.canvas")
    canvas.focusRingType = .exterior
    #expect(canvas.becomeFirstResponder())
    #expect(canvas.focusRingType == .none)
    #expect(canvas.resignFirstResponder())
    #expect(canvas.focusRingMaskBounds == .zero)
    let focusRep = try canvasBitmap(canvas)
    let beforeFocusMask = focusRep.tiffRepresentation
    let context = try #require(NSGraphicsContext(bitmapImageRep: focusRep))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    canvas.drawFocusRingMask()
    NSGraphicsContext.restoreGraphicsState()
    #expect(focusRep.tiffRepresentation == beforeFocusMask)
    for (appearance, expected): (NSAppearance.Name, [Double]) in [(.aqua, [1, 1, 1]),
        (.darkAqua, [15.0 / 255, 17.0 / 255, 21.0 / 255])] {
        canvas.appearance = NSAppearance(named: appearance)
        let rep = try canvasBitmap(canvas)
        let pixel = try #require(rep.colorAt(x: 0, y: 0))
        #expect(abs(pixel.redComponent - expected[0]) < 0.02)
        #expect(abs(pixel.greenComponent - expected[1]) < 0.02)
        #expect(abs(pixel.blueComponent - expected[2]) < 0.02)
    }
    var tabs: [Bool] = [], commands: [CommandID] = []
    var focus = 0
    canvas.onCanvasFocus = { focus += 1 }
    canvas.onTab = { tabs.append($0) }
    canvas.onCommand = { commands.append($0); return true }
    func key(_ text: String, code: UInt16 = 18, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code))
    }
    canvas.keyDown(with: try key("\t", code: 48))
    canvas.keyDown(with: try key("\t", code: 48, modifiers: [.shift]))
    canvas.keyDown(with: try key("1"))
    #expect(tabs == [false, true])
    #expect(commands == [.actualPixels])
    canvas.keyDown(with: try key("x", modifiers: [.control]))
    canvas.keyDown(with: try key("x"))
    canvas.onCommand = { _ in false }
    canvas.keyDown(with: try key("1"))
    canvas.onCommand = nil
    canvas.keyDown(with: try key("1"))
    canvas.mouseDragged(with: try canvasMouse(canvas, .leftMouseDragged, .zero))
    canvas.mouseDown(with: try canvasMouse(canvas, .leftMouseDown, .zero))
    #expect(focus == 1)
    #expect(canvas.apply(.actualPixels, from: .key) == nil)
    canvas.magnify(by: 1, at: .zero)
    canvas.synchronizeViewport()
    canvas.viewDidChangeBackingProperties()
    canvas.beginOpening()
    #expect(!canvas.hasImage)
    let opening = try canvasBitmap(canvas)
    canvas.showFailure()
    let failure = try canvasBitmap(canvas)
    // P1-07 owns both messages in the state surface; the canvas stays blank in both.
    #expect(opening.tiffRepresentation == failure.tiffRepresentation)
    canvas.install(try canvasImage(.init(width: 800, height: 400)))
    #expect(canvas.apply(.open, from: .menu) == nil)
    canvas.onCommand = { CommandRouter().route($0, from: .key, to: canvas.session) }
    canvas.keyDown(with: try key("1"))
    #expect(canvas.session.zoomMode == .actualPixels)
    canvas.viewDidChangeBackingProperties()
    #expect(canvas.session.zoomMode == .actualPixels)
    canvas.showFailure()
    #expect(!canvas.hasImage)
    #expect(try canvasRedBounds(canvas).width == 0)
}

@MainActor private final class CanvasPointerWindow: NSWindow {
    var showsCanvas = false
    var pointer = CGPoint.zero
    override var isVisible: Bool { showsCanvas }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

@Test @MainActor func canvasViewZoomCommandsUsePointerAndDetachedViewport() throws {
    _ = NSApplication.shared
    let session = ViewerSession()
    let canvas = CanvasView(frame: .init(x: 0, y: 0, width: 432, height: 232), session: session)
    canvas.install(try canvasImage(.init(width: 800, height: 400)))
    #expect(canvas.apply(.zoomIn, from: .button) == 0.625)
    #expect(canvas.apply(.zoomOut, from: .button) == 0.5)
    let window = CanvasPointerWindow(contentRect: .init(x: -20000, y: -20000, width: 432, height: 232),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = canvas
    window.showsCanvas = true
    window.pointer = canvas.convert(.init(x: 216, y: 116), to: nil)
    #expect(canvas.apply(.zoomIn, from: .menu) != nil)
    window.pointer = .init(x: 9000, y: 9000)
    #expect(canvas.apply(.zoomOut, from: .key) != nil)
    canvas.pointerIsOverPanel = { true }
    #expect(canvas.apply(.zoomIn, from: .button) != nil)
    canvas.magnify(by: log(2), at: .init(x: 216, y: 116))
    let custom = session.zoomMode
    canvas.setFrameSize(.init(width: 232, height: 132))
    #expect(session.zoomMode == custom)
    canvas.beginOpening()
    #expect(session.zoomMode == .fit)
    canvas.install(try canvasImage(.init(width: 80, height: 40)))
    let before = try canvasRedBounds(canvas)
    canvas.mouseDown(with: try canvasMouse(canvas, .leftMouseDown, .zero))
    canvas.mouseDragged(with: try canvasMouse(canvas, .leftMouseDragged, .init(x: 1000, y: 1000)))
    #expect(try canvasRedBounds(canvas) == before)
    for theme: NSAppearance.Name in [.aqua, .darkAqua] {
        canvas.appearance = NSAppearance(named: theme)
        #expect(try canvasRedBounds(canvas) == before)
    }
}

@MainActor private final class CanvasTestSurround: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.green.setFill()
        bounds.fill()
    }
}

@Test @MainActor func canvasViewClipsEnlargedImageToItsFrame() throws {
    _ = NSApplication.shared
    let parent = CanvasTestSurround(frame: .init(x: 0, y: 0, width: 140, height: 140))
    let canvas = CanvasView(frame: .init(x: 20, y: 20, width: 100, height: 100), session: ViewerSession())
    parent.addSubview(canvas)
    canvas.install(try canvasImage(.init(width: 800, height: 400)))
    canvas.magnify(by: log(64), at: .init(x: 50, y: 50))
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 140, pixelsHigh: 140,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    parent.cacheDisplay(in: parent.bounds, to: rep)
    let outside = try #require(rep.colorAt(x: 10, y: 70))
    let inside = try #require(rep.colorAt(x: 70, y: 70))
    #expect(outside.greenComponent > 0.9 && outside.redComponent < 0.1)
    #expect(inside.redComponent > 0.9 && inside.greenComponent < 0.1)
}

@Test @MainActor func canvasViewOpeningGenerationRetriesAndSourceDetail() throws {
    let (canvas, window, host) = canvasHost()
    defer { window.close(); withExtendedLifetime(host) {} }
    // One path, two explicit opens. Revision retries reuse the explicit open's generation.
    var generation = UUID()
    canvas.openingGeneration = { generation }
    let router = CommandRouter()
    let small = try canvasImage(.init(width: 80, height: 40))
    canvas.beginOpening()
    canvas.install(small)
    canvas.magnify(by: log(2), at: .init(x: 216, y: 116))
    canvas.mouseDown(with: try canvasMouse(canvas, .leftMouseDown, .init(x: 216, y: 116)))
    canvas.mouseDragged(with: try canvasMouse(canvas, .leftMouseDragged, .init(x: 236, y: 126)))
    canvas.mouseUp(with: try canvasMouse(canvas, .leftMouseUp, .init(x: 236, y: 126)))
    let panned = try canvasRedBounds(canvas)
    canvas.beginOpening() // Revision retry, same generation and displayed dimensions.
    canvas.install(small)
    #expect(canvas.session.zoomMode == .custom(2))
    #expect(try canvasRedBounds(canvas) == panned)
    generation = UUID() // Explicit open of the same file path.
    canvas.beginOpening()
    canvas.install(small)
    #expect(canvas.session.zoomMode == .fit)
    let fitted = window.backingScaleFactor == 1 ? CGRect(x: 176, y: 96, width: 80, height: 40)
                                               : CGRect(x: 196, y: 106, width: 40, height: 20)
    #expect(try canvasRedBounds(canvas) == fitted)

    let large = try canvasImage(.init(width: 4000, height: 2000))
    canvas.install(large)
    #expect(router.route(.actualPixels, from: .key, to: canvas.session))
    var requested: [Int] = []
    canvas.onResolutionNeeded = { requested.append($0) }
    canvas.beginOpening()
    canvas.install(large) // A viewport-sized decode still describes the larger source.
    #expect(canvas.session.zoomMode == .actualPixels)
    #expect(requested == [4000])
    requested.removeAll()
    canvas.install(large) // Detail upgrade retains placement and reports its requirement too.
    #expect(requested == [4000])
    #expect(router.route(.zoomIn, from: .button, to: canvas.session))
    requested.removeAll()
    canvas.beginOpening()
    canvas.install(large)
    #expect(canvas.session.zoomMode == .custom(1.25))
    #expect(requested == [4000])
}

@Test @MainActor func canvasViewFitsDecodedDisplayedPortrait() throws {
    let (canvas, window, host) = canvasHost()
    defer { window.close(); withExtendedLifetime(host) {} }
    // EXIF 5–8 swap the stored 800×400 size. The pipeline supplies displayed 400×800.
    let decoded = try canvasImage(.init(width: 400, height: 800))
    canvas.install(decoded)
    #expect(canvas.session.zoomMode == .fit)
    #expect(try canvasRedBounds(canvas) == CGRect(x: 166, y: 16, width: 100, height: 200))
}

/// #348: each ⌘ zoom key leaves the canvas exactly where its bare key does, pointer inside or outside.
@Test @MainActor func cmdZoomKeysMatchBareKeys() throws {
    _ = NSApplication.shared
    var hosts: [CanvasTestHost] = [] // ViewerSession.host is weak.
    func stack() throws -> (CanvasView, ViewerSession, CanvasPointerWindow) {
        let session = ViewerSession()
        let canvas = CanvasView(frame: .init(x: 0, y: 0, width: 432, height: 232), session: session)
        let window = CanvasPointerWindow(contentRect: .init(x: -20000, y: -20000, width: 432, height: 232),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.showsCanvas = true
        canvas.appearance = NSAppearance(named: .aqua)
        let host = CanvasTestHost()
        host.canvas = canvas
        session.host = host
        hosts.append(host)
        canvas.onCommand = { CommandRouter().route($0, from: .key, to: session) }
        canvas.install(try canvasImage(.init(width: 800, height: 400)))
        return (canvas, session, window)
    }
    let (a, aSession, aWindow) = try stack()
    let (b, bSession, bWindow) = try stack()
    defer { aWindow.close(); bWindow.close(); withExtendedLifetime(hosts) {} }
    func key(_ canvas: CanvasView, _ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws {
        canvas.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    // (⌘ characters, ⌘ key code, bare characters, bare key code)
    let plus = ("+", UInt16(24), "+", UInt16(24)), equals = ("=", UInt16(24), "=", UInt16(24))
    let minus = ("-", UInt16(27), "-", UInt16(27)), unicodeMinus = ("−", UInt16(27), "−", UInt16(27))
    let actual = ("0", UInt16(29), "1", UInt16(18)), fit = ("9", UInt16(25), "0", UInt16(29))
    let sequence = [plus, plus, minus, actual, plus, fit, equals, equals, unicodeMinus, actual, minus, fit]
    var firstPlus: [Data] = []
    for pointer in [a.convert(CGPoint(x: 100, y: 60), to: nil), CGPoint(x: 9000, y: 9000)] {
        aWindow.pointer = pointer
        bWindow.pointer = pointer
        CommandRouter().route(.fit, from: .button, to: aSession)
        CommandRouter().route(.fit, from: .button, to: bSession)
        var modes: [CanvasZoomMode] = []
        for (index, step) in sequence.enumerated() {
            try key(a, step.0, step.1, .command)
            try key(b, step.2, step.3, [])
            #expect(aSession.zoomMode == bSession.zoomMode, "step \(index) at \(pointer)")
            let aPixels = try canvasBitmap(a).tiffRepresentation
            #expect(aPixels == (try canvasBitmap(b).tiffRepresentation), "step \(index) at \(pointer)")
            if index == 0, let aPixels { firstPlus.append(aPixels) }
            modes.append(aSession.zoomMode)
        }
        #expect(modes.contains(.fit) && modes.contains(.actualPixels))
        #expect(modes.contains { if case .custom = $0 { true } else { false } })
    }
    #expect(firstPlus.count == 2 && firstPlus[0] != firstPlus[1], "the pointer anchors ⌘ zoom")
    let mode = aSession.zoomMode
    let pixels = try canvasBitmap(a).tiffRepresentation
    try key(a, "0", 29, [.control, .command])
    try key(a, "0", 29, [.option, .command])
    #expect(aSession.zoomMode == mode)
    #expect(try canvasBitmap(a).tiffRepresentation == pixels)
}
