import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #692 (P7-11) WI-3: the strip enables 箭头 文字 荧光笔 画笔 序号 (C1, C5); the overlay draws every kind through the
// copy's renderer (C2–C4, F10–F12), creates each kind by dragging or clicking, moves, resizes and edits text (O1–O12).
// Expected positions are worked out from page 39 (zoom 0.32, origin 352,16): 1 screen point = 3.125 image pixels.

@MainActor private final class ToolsContainer: NSView {
    var fill: NSColor?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        bounds.fill()
    }
}

private let page39 = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
private let screenStyle = AnnotationStyle.forScreen(pointsPerImagePixel: 0.32)

@MainActor private func host(_ appearance: NSAppearance.Name = .aqua, size: CGSize = CGSize(width: 1280, height: 800),
                             transform: CanvasTransform = page39, imageSize: CGSize = CGSize(width: 1600, height: 2400),
                             fill: NSColor? = nil) -> (AnnotationOverlayView, NSWindow) {
    _ = NSApplication.shared
    let container = ToolsContainer(frame: NSRect(origin: .zero, size: size))
    container.fill = fill
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.appearance = NSAppearance(named: appearance)
    let overlay = AnnotationOverlayView(frame: container.bounds)
    container.addSubview(overlay)
    overlay.transform = transform
    overlay.imageSize = imageSize
    overlay.isActive = true
    overlay.tool = .select
    return (overlay, window)
}

@MainActor private func render(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private func px(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    var p = [Int](repeating: 0, count: 4)
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return p }
    rep.getPixel(&p, atX: x, y: y)
    return p
}

private func px(_ rep: NSBitmapImageRep, _ point: CGPoint) -> [Int] { px(rep, Int(point.x), Int(point.y)) }

private func isRed(_ p: [Int]) -> Bool { p[3] > 200 && p[0] > 180 && p[1] < 110 && p[2] < 110 }
private func isWhite(_ p: [Int]) -> Bool { p[3] > 240 && p[0] > 235 && p[1] > 235 && p[2] > 235 }

@MainActor private func event(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
}

@MainActor private func drag(_ view: NSView, _ points: [CGPoint]) throws {
    guard let first = points.first, let last = points.last else { return }
    view.mouseDown(with: try event(view, .leftMouseDown, first))
    for point in points.dropFirst() { view.mouseDragged(with: try event(view, .leftMouseDragged, point)) }
    view.mouseUp(with: try event(view, .leftMouseUp, last))
}

@MainActor private func click(_ view: NSView, _ point: CGPoint) throws { try drag(view, [point]) }

private func image(_ view: CGPoint) -> CGPoint { page39.viewToImage(view) }
private func near(_ a: CGPoint?, _ b: CGPoint, _ tolerance: Double = 0.01) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

// MARK: - Strip (C1, C5, C1b)

@MainActor private func strip() -> (AnnotateStripView, NSWindow) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = ToolsContainer(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    window.contentView = container
    let strip = AnnotateStripView(frame: .zero)
    container.addSubview(strip)
    strip.update(AnnotateStripState(tool: .rectangle, canUndo: false, canRedo: false, canSave: false, canCopy: false))
    return (strip, window)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692StripEnablesTheNewTools() {
    let (strip, window) = strip()
    defer { window.close() }
    for item: AnnotateStripItem in [.select, .arrow, .rectangle, .text, .highlighter, .pen, .step] {
        #expect(strip.button(item).isEnabled, "\(item)")
    }
    for item: AnnotateStripItem in [.redact, .crop] { #expect(!strip.button(item).isEnabled, "\(item)") }
    #expect(AnnotateStripItem.allCases == [.select, .arrow, .rectangle, .text, .highlighter, .pen, .redact, .crop,
                                           .step, .undo, .redo, .copy, .save, .done], "page 39's order is kept")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692StripTooltipsCarryTheNewLetters() {
    let (strip, window) = strip()
    defer { window.close() }
    let expected: [(AnnotateStripItem, String)] = [(.select, "Select V"), (.arrow, "Arrow A"), (.rectangle, "Rectangle R"),
        (.text, "Text T"), (.highlighter, "Highlighter H"), (.pen, "Pen P"), (.step, "Step N"),
        (.redact, "Redact"), (.crop, "Crop")]
    for (item, tip) in expected { #expect(strip.button(item).toolTip == tip, "\(item)") }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692StripClicksChooseTheNewToolsAndPressedFollows() {
    let (strip, window) = strip()
    defer { window.close() }
    var log: [AnnotateStripAction] = []
    strip.onAction = { log.append($0) }
    let tools: [(AnnotateStripItem, AnnotateTool)] = [(.arrow, .arrow), (.text, .text), (.highlighter, .highlighter),
                                                       (.pen, .pen), (.step, .step)]
    for (item, _) in tools { strip.button(item).performClick(nil) }
    strip.button(.redact).performClick(nil)
    strip.button(.crop).performClick(nil)
    #expect(log == tools.map { .tool($0.1) }, "遮挡 and 裁剪 stay inert")
    for (item, tool) in tools {
        strip.update(AnnotateStripState(tool: tool, canUndo: false, canRedo: false, canSave: false, canCopy: false))
        #expect(strip.button(item).state == .on, "\(item)")
        #expect(strip.button(.rectangle).state == .off)
    }
}

// MARK: - Page 39 drawing (C2, C2b, C3, C4)

/// Page 39's arrow: view tail (446,640), tip (492,572).
private let page39Arrow = AnnotationMark.arrow(tail: image(CGPoint(x: 446, y: 640)), tip: image(CGPoint(x: 492, y: 572)),
                                               style: screenStyle)

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ArrowOnScreenMatchesPage39InBothAppearances() throws {
    var bytes: [[Int]] = []
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let (overlay, window) = host(name)
        defer { window.close() }
        overlay.marks = [page39Arrow]
        let rep = try render(overlay)
        let shaft = px(rep, 469, 605)
        #expect(abs(shaft[0] - 220) <= 1 && abs(shaft[1] - 38) <= 1 && abs(shaft[2] - 38) <= 1 && shaft[3] == 255,
                "\(name) shaft \(shaft)")
        // Arms 14 pt at ±42° from the reversed shaft; 1 pt in from each arm end is red.
        let tip = CGPoint(x: 492, y: 572), back = atan2(640.0 - 572, 446.0 - 492)
        var arms: [CGPoint] = []
        for sign in [-1.0, 1.0] {
            let angle = back + sign * 42 * .pi / 180
            arms.append(CGPoint(x: tip.x + 14 * cos(angle), y: tip.y + 14 * sin(angle)))
            let inner = CGPoint(x: tip.x + 13 * cos(angle), y: tip.y + 13 * sin(angle))
            #expect(isRed(px(rep, inner)), "\(name) arm \(sign) \(px(rep, inner))")
        }
        // Shaft 3 pt: 4 pt off the centre line is clear.
        #expect(px(rep, 469 + 4, 605 + 3)[3] < 60, "\(name) shaft width")
        // The head is open: the centroid of the tip, one arm end and the arms' midpoint is not red.
        let mid = CGPoint(x: (arms[0].x + arms[1].x) / 2, y: (arms[0].y + arms[1].y) / 2)
        let inside = CGPoint(x: (tip.x + arms[0].x + mid.x) / 3, y: (tip.y + arms[0].y + mid.y) / 3)
        #expect(!isRed(px(rep, inside)) && px(rep, inside)[3] < 128, "\(name) open head \(px(rep, inside))")
        bytes.append(shaft + px(rep, inside) + px(rep, 600, 300))
    }
    #expect(bytes[0] == bytes[1], "marks ignore the appearance")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692StepOnScreenIsARedDiscWithAWhiteNumber() throws {
    let centre = CGPoint(x: 600, y: 400)
    var bytes: [[Int]] = []
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let (overlay, window) = host(name)
        defer { window.close() }
        overlay.marks = [AnnotationMark.step(centre: image(centre), style: screenStyle)]
        let rep = try render(overlay)
        #expect(isRed(px(rep, 590, 400)), "\(name) fill \(px(rep, 590, 400))")
        #expect(px(rep, 615, 400)[3] < 60, "\(name) diameter 28")
        #expect(px(rep, 585, 400)[3] < 60, "\(name) diameter 28")
        var white = 0
        for y in 392...408 { for x in 594...606 { guard isWhite(px(rep, x, y)) else { continue }; white += 1 } }
        #expect(white >= 6, "\(name) the number is white: \(white)")
        bytes.append(px(rep, 590, 400) + px(rep, 600, 400) + px(rep, 600, 396))
    }
    #expect(bytes[0] == bytes[1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692TextOnScreenIsRedWithAWhiteHalo() throws {
    let size = AnnotationRenderer.textSize("Hi", fontSize: 18 * screenStyle.unit)
    let mark = AnnotationMark.text("Hi", origin: image(CGPoint(x: 600, y: 400)), size: size, style: screenStyle)
    let viewHeight = mark.rect.height * 0.32
    #expect(viewHeight >= 21 && viewHeight <= 24, "18 pt text: \(viewHeight)")
    var bytes: [[Int]] = []
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let (overlay, window) = host(name)
        defer { window.close() }
        overlay.marks = [mark]
        let rep = try render(overlay)
        var red = 0, white = 0
        for y in 400..<Int(400 + viewHeight) {
            for x in 600..<Int(600 + mark.rect.width * 0.32) {
                let p = px(rep, x, y)
                if isRed(p) { red += 1 }
                if isWhite(p) { white += 1 }
            }
        }
        #expect(red > 10 && white > 4, "\(name) red \(red) white \(white)")
        bytes.append([red, white])
    }
    #expect(bytes[0] == bytes[1])
}

// MARK: - Screen and copy look the same (F10, F10′, F11, F12)

private func sixKinds(lineWidth: Double) -> [AnnotationMark] {
    let style = AnnotationStyle(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255, lineWidth: lineWidth)
    let u = lineWidth / 3
    return [
        AnnotationMark(rect: CGRect(x: 20, y: 20, width: 100, height: 60), style: style),
        .arrow(tail: CGPoint(x: 40, y: 260), tip: CGPoint(x: 160, y: 140), style: style),
        .stroke(.highlighter, points: [CGPoint(x: 200, y: 40), CGPoint(x: 300, y: 120), CGPoint(x: 300, y: 40),
                                       CGPoint(x: 200, y: 120)], style: style),
        .stroke(.pen, points: [CGPoint(x: 200, y: 200), CGPoint(x: 250, y: 260), CGPoint(x: 300, y: 200)], style: style),
        .step(centre: CGPoint(x: 350, y: 250), style: style),
        .text("Mado", origin: CGPoint(x: 320, y: 140),
              size: AnnotationRenderer.textSize("Mado", fontSize: 18 * u), style: style),
    ]
}

private func white(_ width: Int, _ height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// sRGB bytes of `image`, rows top first.
private func bytes(_ image: CGImage) throws -> (Int, Int) -> [Int] {
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let copy = data
    return { x, y in
        let i = (y * width + x) * 4
        return [Int(copy[i]), Int(copy[i + 1]), Int(copy[i + 2]), Int(copy[i + 3])]
    }
}

/// Renders `marks` on screen at `zoom` over white, and flattens them onto a white 400×300 copy.
@MainActor private func screenAndCopy(_ marks: [AnnotationMark], zoom: Double)
    throws -> (screen: (CGPoint) -> [Int], copy: (CGPoint) -> [Int]) {
    let transform = CanvasTransform(backingScale: 1, zoom: zoom, origin: .zero)
    let (overlay, window) = host(size: CGSize(width: 400 * zoom, height: 300 * zoom), transform: transform,
                                 imageSize: CGSize(width: 400, height: 300), fill: .white)
    defer { window.close() }
    overlay.marks = marks
    let rep = try render(try #require(overlay.superview))
    let copy = try bytes(AnnotationFlattener.flatten(try white(400, 300), orientation: 1, marks: marks))
    return ({ px(rep, Int($0.x * zoom), Int($0.y * zoom)) }, { copy(Int($0.x), Int($0.y)) })
}

private func diff(_ a: [Int], _ b: [Int]) -> Int { zip(a.prefix(3), b.prefix(3)).map { abs($0 - $1) }.max() ?? 0 }

/// Interior pixels (image coordinates) whose screen and copy colours must agree closely.
private let keyPixels: [CGPoint] = [
    CGPoint(x: 70, y: 20),      // rectangle edge
    CGPoint(x: 100, y: 200),    // arrow shaft
    CGPoint(x: 225, y: 60),     // highlighter, single pass
    CGPoint(x: 250, y: 80),     // highlighter, where the X crosses
    CGPoint(x: 225, y: 230),    // pen
    CGPoint(x: 340, y: 250),    // step disc
]

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ScreenAndCopyLookTheSameAtOneToOne() throws {
    let (screen, copy) = try screenAndCopy(sixKinds(lineWidth: 3), zoom: 1)
    var close = 0
    for y in 0..<300 { for x in 0..<400 { guard diff(screen(CGPoint(x: x, y: y)), copy(CGPoint(x: x, y: y))) <= 16 else { continue }; close += 1 } }
    #expect(Double(close) / 120_000 >= 0.99, "\(close) of 120000 within 16")
    for point in keyPixels {
        #expect(diff(screen(point), copy(point)) <= 4, "\(point): screen \(screen(point)) copy \(copy(point))")
    }
    // The highlighter crossing is one pass, not two: it equals the single-pass pixel.
    #expect(diff(screen(CGPoint(x: 250, y: 80)), screen(CGPoint(x: 225, y: 60))) <= 3)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ScreenAtHalfZoomFollowsTheStoredWidths() throws {
    // lineWidth 6 drawn at zoom 0.5 is 3 pt on screen: the same picture as the copy, half size.
    let (screen, copy) = try screenAndCopy(sixKinds(lineWidth: 6), zoom: 0.5)
    for point in [CGPoint(x: 100, y: 200), CGPoint(x: 225, y: 60), CGPoint(x: 340, y: 250)] {
        #expect(diff(screen(point), copy(point)) <= 16, "\(point): screen \(screen(point)) copy \(copy(point))")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ScreenDrawsTheStoredWidthNotTheCurrentZoom() throws {
    let style = AnnotationStyle(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255, lineWidth: 6)
    let (overlay, window) = host(size: CGSize(width: 400, height: 300),
                                 transform: CanvasTransform(backingScale: 1, zoom: 1, origin: .zero),
                                 imageSize: CGSize(width: 400, height: 300))
    defer { window.close() }
    overlay.marks = [.arrow(tail: CGPoint(x: 20, y: 150), tip: CGPoint(x: 380, y: 150), style: style)]
    let rep = try render(overlay)
    #expect(isRed(px(rep, 100, 150)) && isRed(px(rep, 100, 152)) && isRed(px(rep, 100, 147)), "6 pt shaft")
    #expect(px(rep, 100, 154)[3] < 60 && px(rep, 100, 145)[3] < 60, "not wider than 6 pt")
    let text = AnnotationMark.text("Hi", origin: CGPoint(x: 20, y: 20),
                                   size: AnnotationRenderer.textSize("Hi", fontSize: 18 * style.unit), style: style)
    #expect(text.rect.height >= 42 && text.rect.height <= 48, "\(text.rect.height)")
}

// MARK: - Creating marks (O1–O5)

@Test(.timeLimit(.minutes(2))) @MainActor func issue692DragCreatesArrowHighlighterAndPen() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    overlay.tool = .arrow
    try drag(overlay, [CGPoint(x: 400, y: 200), CGPoint(x: 450, y: 220), CGPoint(x: 500, y: 300)])
    overlay.tool = .highlighter
    try drag(overlay, [CGPoint(x: 400, y: 400), CGPoint(x: 450, y: 410), CGPoint(x: 500, y: 400)])
    overlay.tool = .pen
    let pen = [CGPoint(x: 400, y: 500), CGPoint(x: 420, y: 520), CGPoint(x: 440, y: 505), CGPoint(x: 460, y: 530)]
    try drag(overlay, pen)
    #expect(added.map(\.kind) == [.arrow, .highlighter, .pen])
    guard added.count == 3 else { return }
    #expect(near(added[0].points.first, image(CGPoint(x: 400, y: 200))) && near(added[0].points.last, image(CGPoint(x: 500, y: 300))))
    #expect(abs(added[0].style.lineWidth - 9.375) < 1e-9, "3 pt at zoom 0.32")
    #expect(added[2].points.count == pen.count, "the pen keeps every sample")
    for (stored, sample) in zip(added[2].points, pen) { #expect(near(stored, image(sample)), "\(stored)") }
    #expect(added[1].points.count >= 3)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ZeroLengthDragAddsNothing() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    for tool: AnnotateTool in [.arrow, .rectangle, .highlighter, .pen] {
        overlay.tool = tool
        try drag(overlay, [CGPoint(x: 600, y: 400), CGPoint(x: 601, y: 401)])
        try click(overlay, CGPoint(x: 620, y: 420))
    }
    #expect(added == [])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692StepClickPlacesAMarkerAtTheClick() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    overlay.tool = .step
    try click(overlay, CGPoint(x: 600, y: 400))
    #expect(added.map(\.kind) == [.step])
    #expect(near(added.first?.points.first, image(CGPoint(x: 600, y: 400))))
    #expect(added.first.map { abs($0.rect.width - 28 * 3.125) < 1e-6 } == true, "28 pt on screen")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692CancelDragDropsTheDragAndItsPreview() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    overlay.tool = .arrow
    #expect(!overlay.cancelDrag(), "nothing to cancel")
    overlay.mouseDown(with: try event(overlay, .leftMouseDown, CGPoint(x: 400, y: 300)))
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 600, y: 300)))
    #expect(overlay.isDragging)
    #expect(isRed(px(try render(overlay), 500, 300)), "the preview shows during the drag")
    #expect(overlay.cancelDrag())
    #expect(!overlay.isDragging)
    #expect(!isRed(px(try render(overlay), 500, 300)), "the preview is gone")
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 650, y: 300)))
    overlay.mouseUp(with: try event(overlay, .leftMouseUp, CGPoint(x: 650, y: 300)))
    #expect(added == [])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ToolChangeMidDragCancelsIt() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    overlay.tool = .pen
    overlay.mouseDown(with: try event(overlay, .leftMouseDown, CGPoint(x: 400, y: 300)))
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 500, y: 350)))
    overlay.tool = .arrow
    #expect(!overlay.isDragging)
    overlay.mouseUp(with: try event(overlay, .leftMouseUp, CGPoint(x: 600, y: 300)))
    #expect(added == [])
}

// MARK: - Select, move, resize (O6–O8, O11)

private let boxMark = AnnotationMark(rect: CGRect(x: 100, y: 100, width: 400, height: 400), style: screenStyle)
// Image (100,100)–(500,500) is view (384,48)–(512,176).

@Test(.timeLimit(.minutes(2))) @MainActor func issue692SelectDragMovesAMarkWithOneReplace() throws {
    let (overlay, window) = host()
    defer { window.close() }
    overlay.marks = [boxMark]
    var replaced: [(Int, AnnotationMark)] = []
    var selected: [Int?] = []
    overlay.onReplace = { replaced.append(($0, $1)) }
    overlay.onSelect = { selected.append($0) }
    overlay.mouseDown(with: try event(overlay, .leftMouseDown, CGPoint(x: 450, y: 100)))
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 455, y: 105)))
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 460, y: 110)))
    #expect(isRed(px(try render(overlay), 394, 120)), "the moved left edge shows during the drag")
    #expect(replaced.isEmpty, "nothing is committed before mouse-up")
    overlay.mouseUp(with: try event(overlay, .leftMouseUp, CGPoint(x: 460, y: 110)))
    #expect(replaced.count == 1)
    #expect(replaced.first?.0 == 0)
    #expect(replaced.first?.1.rect == CGRect(x: 131.25, y: 131.25, width: 400, height: 400))
    #expect(replaced.first?.1.style == boxMark.style)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692PlainClickSelectsWithoutReplacing() throws {
    let (overlay, window) = host()
    defer { window.close() }
    let pen = AnnotationMark.stroke(.pen, points: [CGPoint(x: 1000, y: 1000), CGPoint(x: 1300, y: 1000)], style: screenStyle)
    overlay.marks = [boxMark, pen]
    var replaced = 0
    var selected: [Int?] = []
    overlay.onReplace = { _, _ in replaced += 1 }
    overlay.onSelect = { selected.append($0) }
    try click(overlay, CGPoint(x: 450, y: 100))
    try click(overlay, page39.imageToView(CGPoint(x: 1150, y: 1000)))
    try click(overlay, page39.imageToView(CGPoint(x: 1150, y: 1100)))
    try click(overlay, CGPoint(x: 700, y: 700))
    #expect(replaced == 0)
    #expect(selected == [0, 1, nil, nil], "a pen is hit on its path, not its box")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692HandleDragResizesTheSelectedMark() throws {
    let (overlay, window) = host()
    defer { window.close() }
    let arrow = AnnotationMark.arrow(tail: CGPoint(x: 800, y: 1500), tip: CGPoint(x: 1200, y: 1500), style: screenStyle)
    overlay.marks = [boxMark, arrow]
    var replaced: [(Int, AnnotationMark)] = []
    overlay.onReplace = { replaced.append(($0, $1)) }
    overlay.selectedMark = 0
    try drag(overlay, [CGPoint(x: 512, y: 176), CGPoint(x: 522, y: 186), CGPoint(x: 532, y: 196)])
    #expect(replaced.first?.1.rect == CGRect(x: 100, y: 100, width: 462.5, height: 462.5))
    overlay.selectedMark = 1
    let tip = page39.imageToView(CGPoint(x: 1200, y: 1500))
    try drag(overlay, [tip, CGPoint(x: tip.x, y: tip.y + 32)])
    #expect(replaced.count == 2)
    #expect(replaced.last?.0 == 1)
    #expect(near(replaced.last?.1.points.last, CGPoint(x: 1200, y: 1600)) && near(replaced.last?.1.points.first, CGPoint(x: 800, y: 1500)))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692HandlesAreDrawnOnlyForResizableKinds() throws {
    let (overlay, window) = host()
    defer { window.close() }
    let step = AnnotationMark.step(centre: CGPoint(x: 1000, y: 1800), style: screenStyle)
    overlay.marks = [boxMark, step]
    overlay.selectedMark = 0
    var rep = try render(overlay)
    for point in [CGPoint(x: 384, y: 48), CGPoint(x: 448, y: 48), CGPoint(x: 512, y: 112), CGPoint(x: 512, y: 176),
                  CGPoint(x: 448, y: 176), CGPoint(x: 384, y: 176), CGPoint(x: 384, y: 112), CGPoint(x: 512, y: 48)] {
        #expect(isWhite(px(rep, point)), "handle at \(point): \(px(rep, point))")
    }
    overlay.selectedMark = 1
    rep = try render(overlay)
    let corner = page39.imageToView(CGPoint(x: step.rect.minX, y: step.rect.minY))
    #expect(!isWhite(px(rep, corner)), "a step marker moves only: no handles")
    #expect(!isWhite(px(rep, 384, 48)), "the box is no longer selected")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692CancelDragMidMoveKeepsTheMark() throws {
    let (overlay, window) = host()
    defer { window.close() }
    overlay.marks = [boxMark]
    overlay.selectedMark = 0
    var replaced = 0
    overlay.onReplace = { _, _ in replaced += 1 }
    overlay.mouseDown(with: try event(overlay, .leftMouseDown, CGPoint(x: 450, y: 100)))
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 480, y: 130)))
    #expect(overlay.cancelDrag())
    overlay.mouseUp(with: try event(overlay, .leftMouseUp, CGPoint(x: 480, y: 130)))
    #expect(replaced == 0)
    #expect(overlay.marks == [boxMark])
    #expect(isRed(px(try render(overlay), 384, 120)), "drawn where it was")
}

// MARK: - Text (O9, O10, O12)

@Test(.timeLimit(.minutes(2))) @MainActor func issue692TextToolEditsAndCommitsOnce() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var commits: [(Int?, String, CGPoint, AnnotationStyle)] = []
    overlay.onCommitText = { commits.append(($0, $1, $2, $3)) }
    var added = 0
    overlay.onAddMark = { _ in added += 1 }
    overlay.tool = .text
    try click(overlay, CGPoint(x: 600, y: 400))
    #expect(overlay.isEditingText)
    let field = try #require(overlay.textEditor)
    #expect(field.superview === overlay)
    #expect(abs(field.frame.minX - 600) <= 4 && abs(field.frame.minY - 400) <= 4, "\(field.frame)")
    #expect(abs((field.font?.pointSize ?? 0) - 18) < 0.01, "18 pt on screen")
    #expect(field.accessibilityLabel()?.isEmpty == false)
    field.stringValue = "Hello"
    #expect(overlay.commitText())
    #expect(!overlay.commitText(), "a second commit reports nothing")
    #expect(!overlay.isEditingText && overlay.textEditor == nil)
    #expect(commits.count == 1 && added == 0, "text goes through onCommitText, not onAddMark")
    #expect(commits.first?.0 == nil && commits.first?.1 == "Hello")
    #expect(near(commits.first?.2, image(CGPoint(x: 600, y: 400))))
    #expect(commits.first.map { abs($0.3.lineWidth - 9.375) < 1e-9 } == true)

    try click(overlay, CGPoint(x: 700, y: 500))
    overlay.textEditor?.stringValue = ""
    overlay.commitText()
    #expect(commits.count == 2 && commits.last?.1 == "", "empty text is reported; the session drops it")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692TextToolEditsAnExistingTextMark() throws {
    let (overlay, window) = host()
    defer { window.close() }
    let size = AnnotationRenderer.textSize("Note", fontSize: 18 * screenStyle.unit)
    let note = AnnotationMark.text("Note", origin: image(CGPoint(x: 600, y: 400)), size: size, style: screenStyle)
    overlay.marks = [boxMark, note]
    var commits: [(Int?, String)] = []
    overlay.onCommitText = { index, text, _, _ in commits.append((index, text)) }
    overlay.tool = .text
    try click(overlay, CGPoint(x: 605, y: 408))
    #expect(overlay.editingMark == 1, "the clicked text mark is edited, not a new one")
    #expect(overlay.textEditor?.stringValue == "Note")
    overlay.textEditor?.stringValue = "Note 2"
    overlay.commitText()
    #expect(commits.count == 1 && commits.first?.0 == 1 && commits.first?.1 == "Note 2")
    #expect(overlay.editingMark == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ClickElsewhereOrToolChangeCommitsTheText() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var commits: [String] = []
    overlay.onCommitText = { _, text, _, _ in commits.append(text) }
    overlay.tool = .text
    try click(overlay, CGPoint(x: 600, y: 400))
    overlay.textEditor?.stringValue = "one"
    try click(overlay, CGPoint(x: 700, y: 600))
    #expect(commits == ["one"], "the click commits once")
    #expect(!overlay.isEditingText, "and does not open a second field")
    try click(overlay, CGPoint(x: 700, y: 600))
    overlay.textEditor?.stringValue = "two"
    overlay.tool = .arrow
    #expect(commits == ["one", "two"])
    #expect(!overlay.isEditingText)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ReturnAndEscapeEndTypingAndTheFieldGrowsWithTheText() throws {
    let (overlay, window) = host()
    defer { window.close() }
    var commits: [String] = []
    overlay.onCommitText = { _, text, _, _ in commits.append(text) }
    overlay.tool = .text
    try click(overlay, CGPoint(x: 600, y: 400))
    let field = try #require(overlay.textEditor)
    let narrow = field.frame.width
    field.stringValue = "a much longer line of annotation text"
    overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(field.frame.width > narrow, "the field widens as the text grows")
    #expect(abs(field.frame.minX - 600) <= 4, "and keeps its origin")
    let textView = NSTextView()
    #expect(!overlay.control(field, textView: textView, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    #expect(overlay.isEditingText && commits.isEmpty, "other commands stay with the field")
    #expect(overlay.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(!overlay.isEditingText && commits == ["a much longer line of annotation text"], "Return commits")
    try click(overlay, CGPoint(x: 700, y: 500))
    overlay.textEditor?.stringValue = "esc"
    let second = try #require(overlay.textEditor)
    #expect(overlay.control(second, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!overlay.isEditingText && commits.last == "esc", "Esc commits too; it does not discard")
}
