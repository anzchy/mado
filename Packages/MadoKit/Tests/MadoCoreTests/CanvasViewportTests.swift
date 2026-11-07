import CoreGraphics
import Testing
import MadoCore

@Test func canvasViewportModesGrowShrinkFullscreenAndBackingScale() {
    let source = CGSize(width: 800, height: 400)
    let old = CGSize(width: 432, height: 232)
    let grow = CGSize(width: 832, height: 432)
    let shrink = CGSize(width: 232, height: 132)
    let fullscreen = CGSize(width: 1632, height: 832)
    let cases: [(CanvasZoomMode, Double, CGPoint, Double, CGPoint, Double, CGPoint)] = [
        (.fit, 0.5, .init(x: 16, y: 16), 1, .init(x: 16, y: 16), 0.25, .init(x: 16, y: 16)),
        (.actualPixels, 1, .init(x: -184, y: -84), 1, .init(x: 16, y: 16), 1, .init(x: -284, y: -134)),
        (.custom(2), 2, .init(x: -584, y: -284), 2, .init(x: -384, y: -184), 2, .init(x: -684, y: -334))
    ]
    for (mode, zoom, origin, grownZoom, grownOrigin, shrunkZoom, shrunkOrigin) in cases {
        let initial = CanvasTransform(backingScale: 1, zoom: zoom, origin: origin)
        var transform = initial
        transform.viewportChanged(source: source, from: old, to: grow, backingScale: 1, mode: mode)
        #expect(transform.zoom == grownZoom)
        #expect(transform.origin == grownOrigin)
        transform = initial
        transform.viewportChanged(source: source, from: old, to: shrink, backingScale: 1, mode: mode)
        #expect(transform.zoom == shrunkZoom)
        #expect(transform.origin == shrunkOrigin)
        transform = initial
        transform.viewportChanged(source: source, from: old, to: fullscreen, backingScale: 1, mode: mode)
        transform.viewportChanged(source: source, from: fullscreen, to: old, backingScale: 1, mode: mode)
        #expect(transform.zoom == zoom)
        #expect(abs(transform.origin.x - origin.x) <= 0.5)
        #expect(abs(transform.origin.y - origin.y) <= 0.5)
    }
    for mode: CanvasZoomMode in [.fit, .actualPixels, .custom(2)] {
        var transform = CanvasTransform(backingScale: 1, zoom: mode == .custom(2) ? 2 : 1,
            origin: mode == .custom(2) ? CGPoint(x: -584, y: -284) : CGPoint(x: -184, y: -84))
        transform.viewportChanged(source: source, from: old, to: old, backingScale: 2, mode: mode)
        #expect(transform.zoom == (mode == .custom(2) ? 2 : 1))
        #expect(transform.origin == (mode == .custom(2) ? CGPoint(x: -184, y: -84) : CGPoint(x: 16, y: 16)))
    }
    // Bounds win when a previous off-centre anchor leaves a gap after resizing.
    var offset = CanvasTransform(backingScale: 2, zoom: 1, origin: .init(x: 999, y: -999))
    offset.viewportChanged(source: source, from: old, to: old, backingScale: 2, mode: .actualPixels)
    #expect(offset.origin == CGPoint(x: 32, y: 0))
}

@Test func canvasViewportRetinaRoundTripsEachMode() {
    let source = CGSize(width: 1600, height: 800)
    let old = CGSize(width: 432, height: 232)
    let cases: [(CanvasZoomMode, Double, CGPoint, Double, CGPoint, Double, CGPoint)] = [
        (.fit, 0.5, .init(x: 16, y: 16), 1, .init(x: 16, y: 16), 0.25, .init(x: 16, y: 16)),
        (.actualPixels, 1, .init(x: -184, y: -84), 1, .init(x: 16, y: 16), 1, .init(x: -284, y: -134)),
        (.custom(2), 2, .init(x: -584, y: -284), 2, .init(x: -384, y: -184), 2, .init(x: -684, y: -334))
    ]
    for (mode, zoom, origin, growZoom, growOrigin, shrinkZoom, shrinkOrigin) in cases {
        let initial = CanvasTransform(backingScale: 2, zoom: zoom, origin: origin)
        var value = initial
        value.viewportChanged(source: source, from: old, to: .init(width: 832, height: 432), backingScale: 2, mode: mode)
        #expect(value.zoom == growZoom && value.origin == growOrigin)
        value = initial
        value.viewportChanged(source: source, from: old, to: .init(width: 232, height: 132), backingScale: 2, mode: mode)
        #expect(value.zoom == shrinkZoom && value.origin == shrinkOrigin)
        value = initial
        value.viewportChanged(source: source, from: old, to: .init(width: 1632, height: 832), backingScale: 2, mode: mode)
        value.viewportChanged(source: source, from: .init(width: 1632, height: 832), to: old, backingScale: 2, mode: mode)
        #expect(value.zoom == zoom)
        #expect(abs(value.origin.x - origin.x) <= 0.25 && abs(value.origin.y - origin.y) <= 0.25)
    }
}

@Test func canvasActualPixelOddResizeDoesNotAccumulateDrift() {
    let source = CGSize(width: 800, height: 400)
    let base = CGSize(width: 432, height: 232)
    for initialScale: Double in [1, 2] {
        let initialOrigin = initialScale == 1 ? CGPoint(x: -184, y: -84) : CGPoint(x: 16, y: 16)
        var value = CanvasTransform(backingScale: initialScale, origin: initialOrigin)
        for _ in 0..<12 {
            var previous = base
            for (size, scale): (CGSize, Double) in [
                (.init(width: 433, height: 233), initialScale),
                (.init(width: 434, height: 234), 2),
                (.init(width: 435, height: 235), 1),
                (.init(width: 434, height: 234), 2),
                (.init(width: 433, height: 233), initialScale),
                (base, initialScale)
            ] {
                value.viewportChanged(source: source, from: previous, to: size,
                                      backingScale: scale, mode: .actualPixels)
                #expect(value.origin.x * scale == (value.origin.x * scale).rounded())
                #expect(value.origin.y * scale == (value.origin.y * scale).rounded())
                previous = size
            }
            #expect(value.viewToImage(.init(x: 216, y: 116)) == CGPoint(x: 400, y: 200))
            #expect(value.origin == initialOrigin)
        }
    }
}
