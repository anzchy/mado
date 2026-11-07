import CoreGraphics
import Testing
import MadoCore

@Test func canvasPanBoundsAndZoomAnchorException() {
    let viewport = CGSize(width: 100, height: 80)
    let source = CGSize(width: 200, height: 160)
    var large = CanvasTransform(backingScale: 1, origin: .init(x: -50, y: -40))
    large.pan(by: .init(x: 1000, y: 1000), source: source, viewport: viewport)
    #expect(large.origin == .zero)
    large.pan(by: .init(x: -1000, y: -1000), source: source, viewport: viewport)
    #expect(large.origin == CGPoint(x: -100, y: -80))
    let smallSource = CGSize(width: 40, height: 20)
    var small = CanvasTransform(backingScale: 1)
    small.pan(by: .init(x: 1000, y: 1000), source: smallSource, viewport: viewport)
    #expect(small.origin == CGPoint(x: 60, y: 60))
    small.pan(by: .init(x: -1000, y: -1000), source: smallSource, viewport: viewport)
    #expect(small.origin == .zero)
    var mixed = CanvasTransform(backingScale: 1)
    mixed.pan(by: .init(x: -900, y: 900), source: .init(width: 200, height: 20), viewport: viewport)
    #expect(mixed.origin == CGPoint(x: -100, y: 60))
    var zoom = CanvasTransform(backingScale: 1, origin: .init(x: 10, y: 10))
    zoom.zoom(to: 0.5, about: .init(x: 95, y: 75), source: smallSource, viewport: viewport)
    // Still visible: anchor beats the pan bound, even though it opens a gap.
    #expect(zoom.origin == CGPoint(x: 52.5, y: 42.5))
    #expect(zoom.viewToImage(.init(x: 95, y: 75)) == CGPoint(x: 85, y: 65))
    zoom.zoom(to: 64, about: .init(x: -900, y: -900), source: smallSource, viewport: viewport)
    #expect(zoom.origin == .zero) // Otherwise no image pixel remains visible.
    for scale in [1.0, 2.0] {
        var grid = CanvasTransform(backingScale: scale, origin: .init(x: -10.1, y: -10.1))
        grid.pan(by: .init(x: -1000.2, y: -1000.2), source: source,
                 viewport: .init(width: 79.7, height: 59.7), snap: true)
        #expect(grid.origin == (scale == 1 ? CGPoint(x: -120, y: -100) : CGPoint(x: -20, y: -20)))
        grid.pan(by: .init(x: 0.31, y: 0.31), source: source, viewport: viewport, snap: true)
        #expect(grid.origin.x * scale == (grid.origin.x * scale).rounded())
        #expect(grid.origin.y * scale == (grid.origin.y * scale).rounded())
    }
    let fit = CanvasTransform.fitted(source: source, viewport: viewport, backingScale: 1)
    #expect(fit.zoom == 0.3)
    #expect(fit.origin == CGPoint(x: 20, y: 16))
}
