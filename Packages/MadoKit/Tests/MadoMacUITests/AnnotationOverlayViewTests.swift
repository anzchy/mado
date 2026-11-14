import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #690 (P7-11) WI-5: page 39 marks — the fixed paint #dc2626 stroked 3 pt in both appearances (B7), drawing a
// rectangle by dragging, and selecting by clicking.

@MainActor private final class OverlayContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Page 39's placement: 1600×2400 at zoom 0.32, origin (352, 16), in a 1280×800 window.
private let page39Transform = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))

@MainActor private func overlayHost(_ appearance: NSAppearance.Name = .aqua) -> (AnnotationOverlayView, NSWindow) {
    _ = NSApplication.shared
    let container = OverlayContainer(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.appearance = NSAppearance(named: appearance)
    let overlay = AnnotationOverlayView(frame: container.bounds)
    container.addSubview(overlay)
    overlay.transform = page39Transform
    overlay.imageSize = CGSize(width: 1600, height: 2400)
    overlay.isActive = true
    overlay.tool = .rectangle
    return (overlay, window)
}

@MainActor private func pixels(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// sRGB bytes and alpha of one pixel.
private func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> [Int] {
    var p = [Int](repeating: 0, count: 4)
    rep.getPixel(&p, atX: x, y: y)
    return p
}

@MainActor private func mouse(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
}

@MainActor private func drag(_ view: NSView, from a: CGPoint, to b: CGPoint) throws {
    view.mouseDown(with: try mouse(view, .leftMouseDown, a))
    view.mouseDragged(with: try mouse(view, .leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
    view.mouseDragged(with: try mouse(view, .leftMouseDragged, b))
    view.mouseUp(with: try mouse(view, .leftMouseUp, b))
}

private let page39Mark = AnnotationMark(rect: CGRect(x: 150, y: 575, width: 312.5, height: 312.5),
                                        style: .forScreen(pointsPerImagePixel: 0.32))

@Test(.timeLimit(.minutes(2))) @MainActor func issue690MarkPaintSameInLightAndDark() throws {
    var rendered: [[Int]] = []
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let (overlay, window) = overlayHost(name)
        defer { window.close() }
        overlay.marks = [page39Mark]
        let rep = try pixels(overlay)
        let left = try rgba(rep, 399, 250), right = try rgba(rep, 400, 250)
        for p in [left, right] {
            #expect(abs(p[0] - 220) <= 1 && abs(p[1] - 38) <= 1 && abs(p[2] - 38) <= 1 && p[3] == 255, "\(name): \(p)")
        }
        rendered.append(left + right + (try rgba(rep, 550, 300)))
    }
    #expect(rendered[0] == rendered[1], "the mark paint ignores the appearance")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690MarkStrokeIsThreePointsOnScreen() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    overlay.marks = [page39Mark]
    let rep = try pixels(overlay)
    let partial = try rgba(rep, 398, 250)
    #expect(partial[3] > 0 && partial[3] < 255, "\(partial)")
    #expect(try rgba(rep, 397, 250)[3] == 0)
    #expect(try rgba(rep, 402, 250)[3] == 0)
    #expect(try rgba(rep, 450, 250)[3] == 0, "the inside stays clear")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690DragAddsMarkWithScreenWidth() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    try drag(overlay, from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
    #expect(added.count == 1)
    #expect(added.first?.rect == CGRect(x: 150, y: 575, width: 312.5, height: 312.5))
    #expect(added.first.map { abs($0.style.lineWidth - 9.375) < 1e-9 } == true)
    #expect(added.first?.style.red == AnnotationStyle.default.red)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690DragTooSmallAddsNothing() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    try drag(overlay, from: CGPoint(x: 600, y: 400), to: CGPoint(x: 600.5, y: 400.5))
    #expect(added == [])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690DragClampedToImage() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    try drag(overlay, from: CGPoint(x: 400, y: 200), to: CGPoint(x: 1270, y: 790))
    #expect(added.first?.rect.maxX == 1600 && added.first?.rect.maxY == 2400)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690DragWithSelectToolAddsNothing() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    overlay.tool = .select
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    try drag(overlay, from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
    #expect(added == [])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690SelectClickHitsAndClears() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    overlay.tool = .select
    overlay.marks = [AnnotationMark(rect: CGRect(x: 100, y: 100, width: 400, height: 400)),
                     AnnotationMark(rect: CGRect(x: 300, y: 300, width: 400, height: 400))]
    var selections: [Int?] = []
    overlay.onSelect = { selections.append($0) }
    // Image (350, 350) is view (464, 128): inside both, so the topmost (1) wins.
    try drag(overlay, from: CGPoint(x: 464, y: 128), to: CGPoint(x: 464, y: 128))
    try drag(overlay, from: CGPoint(x: 300, y: 700), to: CGPoint(x: 300, y: 700))
    #expect(selections == [1, nil])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690SelectionOutlineDrawn() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    overlay.marks = [page39Mark]
    func accentInBand(_ rep: NSBitmapImageRep) throws -> Bool {
        for y in 210..<290 {
            for x in 394...397 {
                let p = try rgba(rep, x, y)
                if p[3] > 128 && p[2] > p[0] + 60 { return true }
            }
        }
        return false
    }
    #expect(try !accentInBand(pixels(overlay)))
    overlay.selectedMark = 0
    #expect(try accentInBand(pixels(overlay)))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690OverlayPassesThroughWhenInactive() throws {
    let (overlay, window) = overlayHost()
    defer { window.close() }
    let point = CGPoint(x: 600, y: 400)
    #expect(overlay.hitTest(point) === overlay)
    overlay.isActive = false
    #expect(overlay.hitTest(point) == nil)
    var added: [AnnotationMark] = []
    overlay.onAddMark = { added.append($0) }
    try drag(overlay, from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
    #expect(added == [], "an inactive overlay never draws marks")
}
