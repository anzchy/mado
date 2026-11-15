import AppKit
import Testing

// #683 fix round 3 (device smoke smoke683-20261114), F1: the hovered window and the region drag rect must not
// be a fully transparent hole that the window server passes clicks through to the window below.

@MainActor private func round3Mouse(_ type: NSEvent.EventType, _ panel: NSWindow, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                   clickCount: 1, pressure: 1))
}

/// The panel's view rendered into an 8-bit bitmap, as the window server's backing store holds it.
@MainActor private struct Round3Render {
    let rep: NSBitmapImageRep
    let sx: CGFloat
    let sy: CGFloat
    let height: CGFloat

    init(_ panel: NSWindow) throws {
        let view = try #require(panel.contentView)
        rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        sx = CGFloat(rep.pixelsWide) / view.bounds.width
        sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        height = view.bounds.height
    }

    /// Device pixels whose area lies inside `rect` (view points, origin bottom-left).
    func pixels(in rect: CGRect) -> [(x: Int, y: Int)] {
        let x0 = Int((rect.minX * sx).rounded(.up)), x1 = Int((rect.maxX * sx).rounded(.down))
        let y0 = Int(((height - rect.maxY) * sy).rounded(.up)), y1 = Int(((height - rect.minY) * sy).rounded(.down))
        return (x0..<x1).flatMap { x in (y0..<y1).map { (x: x, y: $0) } }
    }

    func color(_ pixel: (x: Int, y: Int)) -> NSColor? { rep.colorAt(x: pixel.x, y: pixel.y) }
    func color(at point: CGPoint) -> NSColor? { rep.colorAt(x: Int(point.x * sx), y: Int((height - point.y) * sy)) }
}

@MainActor private func round3ExpectNotClickThrough(_ panel: NSWindow, inside rect: CGRect) throws {
    #expect(panel.ignoresMouseEvents == false)
    let render = try Round3Render(panel)
    #expect(render.rep.bitsPerSample == 8)
    // Every device pixel of the selection, border included: a fully transparent one passes the click through.
    let all = render.pixels(in: rect)
    #expect(!all.isEmpty)
    let transparent = all.filter { (render.color($0)?.alphaComponent ?? 0) * 255 < 1 }
    #expect(transparent.isEmpty, "\(transparent.count) of \(all.count) selection pixels are fully transparent")
    // Inside the 1 pt border the selection stays visually clear.
    let interior = render.pixels(in: rect.insetBy(dx: 1, dy: 1))
    let tinted = interior.filter { (render.color($0)?.alphaComponent ?? 1) >= 0.05 }
    #expect(tinted.isEmpty, "\(tinted.count) interior pixels are tinted")
    // The white border is still drawn on each edge.
    let edges: [[CGPoint]] = [
        [CGPoint(x: rect.minX - 0.25, y: rect.midY), CGPoint(x: rect.minX + 0.25, y: rect.midY)],
        [CGPoint(x: rect.maxX - 0.25, y: rect.midY), CGPoint(x: rect.maxX + 0.25, y: rect.midY)],
        [CGPoint(x: rect.midX, y: rect.minY - 0.25), CGPoint(x: rect.midX, y: rect.minY + 0.25)],
        [CGPoint(x: rect.midX, y: rect.maxY - 0.25), CGPoint(x: rect.midX, y: rect.maxY + 0.25)]
    ]
    for edge in edges {
        let white = edge.contains { point in
            guard let c = render.color(at: point)?.usingColorSpace(.deviceRGB) else { return false }
            return c.alphaComponent > 0.45 && c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9
        }
        #expect(white, "no white border at \(edge[0])")
    }
    // The dimming outside is unchanged on all four sides.
    // Below the rect, right of the region size label.
    for point in [CGPoint(x: rect.maxX + 10, y: rect.minY / 2), CGPoint(x: rect.midX, y: rect.maxY + 10),
                  CGPoint(x: rect.minX / 2, y: rect.midY), CGPoint(x: rect.maxX + 10, y: rect.midY)] {
        let alpha = render.color(at: point)?.alphaComponent ?? 0
        #expect(abs(alpha - 0.25) < 0.02, "dimming at \(point) is \(alpha)")
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Fix3HoveredWindowIsNotClickThrough() throws {
    let screen = try #require(NSScreen.main)
    let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    let candidates = [ScreenCaptureKitScreen.WindowCandidate(id: 41, frame: CGRect(x: screen.frame.minX + 20,
        y: top - screen.frame.minY - 80, width: 60, height: 60))]
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window, windows: candidates) { _ in }
    defer { panel.orderOut(nil) }
    panel.sendEvent(try round3Mouse(.mouseMoved, panel, CGPoint(x: 50, y: 50)))
    #expect(panel.highlightedWindowID == 41)
    try round3ExpectNotClickThrough(panel, inside: CGRect(x: 20, y: 20, width: 60, height: 60))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Fix3RegionDragRectIsNotClickThrough() throws {
    let screen = try #require(NSScreen.main)
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .region) { _ in }
    defer { panel.orderOut(nil) }
    panel.sendEvent(try round3Mouse(.leftMouseDown, panel, CGPoint(x: 20, y: 20)))
    panel.sendEvent(try round3Mouse(.leftMouseDragged, panel, CGPoint(x: 80, y: 70)))
    try round3ExpectNotClickThrough(panel, inside: CGRect(x: 20, y: 20, width: 60, height: 50))
}
