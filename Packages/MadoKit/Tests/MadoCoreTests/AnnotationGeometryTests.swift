import CoreGraphics
import Foundation
import Testing
import MadoCore

// #690 (P7-11) WI-5: page 39 (annotate.html) geometry — the fit left of the strip (B1, B11), the fixed mark
// paint (B7), and the drag, hit test and nudge of rectangle marks (5.6).

private struct GeometryRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func viewRect(_ t: CanvasTransform, _ source: CGSize) -> CGRect {
    let a = t.imageToView(.zero), b = t.imageToView(CGPoint(x: source.width, y: source.height))
    return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
}

private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

private let page39Image = CGSize(width: 1600, height: 2400)
private let page39Window = CGSize(width: 1280, height: 800)

// MARK: - B1 / B11: the fit left of the strip

@Test(.timeLimit(.minutes(2))) func fitReserve64PlacesPage39Image() {
    let t = CanvasTransform.fitted(source: page39Image, viewport: page39Window, backingScale: 1, trailingReserve: 64)
    #expect(abs(t.zoom - 0.32) < 1e-9)
    #expect(near(viewRect(t, page39Image), CGRect(x: 352, y: 16, width: 512, height: 768), 1e-6))
}

@Test(.timeLimit(.minutes(2))) func fitReserveZeroRestoresNormalFit() {
    let t = CanvasTransform.fitted(source: page39Image, viewport: page39Window, backingScale: 1, trailingReserve: 0)
    #expect(near(viewRect(t, page39Image), CGRect(x: 384, y: 16, width: 512, height: 768), 1e-6))
}

@Test(.timeLimit(.minutes(2))) func fitReserveIsPointBasedAtBacking2() {
    let t = CanvasTransform.fitted(source: page39Image, viewport: page39Window, backingScale: 2, trailingReserve: 64)
    #expect(near(viewRect(t, page39Image), CGRect(x: 352, y: 16, width: 512, height: 768), 1e-6))
}

@Test(.timeLimit(.minutes(2))) func fitReserveWideImageStaysLeftOfStrip() {
    let wide = CGSize(width: 4000, height: 1000)
    let rect = viewRect(.fitted(source: wide, viewport: page39Window, backingScale: 1, trailingReserve: 64), wide)
    #expect(abs(rect.maxX - 1200) < 1e-6)
    #expect(abs(rect.minX - 16) < 1e-6)
}

@Test(.timeLimit(.minutes(2))) func fitReserveInsideAreaProperty() {
    for seed in UInt64(1)...400 {
        var random = GeometryRandom(seed: seed)
        let source = CGSize(width: Double.random(in: 1...8000, using: &random).rounded(),
                            height: Double.random(in: 1...8000, using: &random).rounded())
        let viewport = CGSize(width: Double.random(in: 200...3000, using: &random).rounded(),
                              height: Double.random(in: 200...2000, using: &random).rounded())
        let reserve = Bool.random(using: &random) ? 64.0 : 0
        let t = CanvasTransform.fitted(source: source, viewport: viewport, backingScale: 1, trailingReserve: reserve)
        let rect = viewRect(t, source)
        // A tiny image keeps 1:1 and is snapped to whole points; it still sits in the area left of the strip.
        #expect(rect.maxX <= viewport.width - reserve - 16 + 0.5 || t.zoom == 1, "seed \(seed)")
        #expect(abs(rect.midX - (viewport.width - reserve) / 2) <= 0.5, "seed \(seed)")
        #expect(abs(rect.midY - viewport.height / 2) <= 0.5, "seed \(seed)")
        if t.zoom < 1, t.zoom > CanvasTransform.zoomLimits.lowerBound {
            #expect(rect.minX >= 16 - 1e-6 && rect.maxX <= viewport.width - reserve - 16 + 1e-6, "seed \(seed)")
            #expect(rect.minY >= 16 - 1e-6 && rect.maxY <= viewport.height - 16 + 1e-6, "seed \(seed)")
        }
    }
}

@Test(.timeLimit(.minutes(2))) func fitReserveZeroMatchesLegacyFit() {
    for seed in UInt64(1)...400 {
        var random = GeometryRandom(seed: seed)
        let source = CGSize(width: Double.random(in: 1...8000, using: &random).rounded(),
                            height: Double.random(in: 1...8000, using: &random).rounded())
        let viewport = CGSize(width: Double.random(in: 200...3000, using: &random).rounded(),
                              height: Double.random(in: 200...2000, using: &random).rounded())
        let scale = Bool.random(using: &random) ? 2.0 : 1
        let legacy = CanvasTransform.fitted(source: source, viewport: viewport, backingScale: scale)
        let zero = CanvasTransform.fitted(source: source, viewport: viewport, backingScale: scale, trailingReserve: 0)
        #expect(legacy.zoom == zero.zoom && legacy.origin == zero.origin, "seed \(seed)")
    }
}

@Test(.timeLimit(.minutes(2))) func viewportChangedKeepsReserveInFitMode() {
    var t = CanvasTransform.fitted(source: page39Image, viewport: page39Window, backingScale: 1, trailingReserve: 64)
    let larger = CGSize(width: 1440, height: 900)
    t.viewportChanged(source: page39Image, from: page39Window, to: larger, backingScale: 1, mode: .fit, trailingReserve: 64)
    let expected = CanvasTransform.fitted(source: page39Image, viewport: larger, backingScale: 1, trailingReserve: 64)
    #expect(t.zoom == expected.zoom && t.origin == expected.origin)
    #expect(near(viewRect(t, page39Image), CGRect(x: 398.6667, y: 16, width: 578.6667, height: 868), 0.01))
}

@Test(.timeLimit(.minutes(2))) func viewportChangedReserveProperty() {
    for seed in UInt64(1)...300 {
        var random = GeometryRandom(seed: seed)
        let source = CGSize(width: Double.random(in: 50...6000, using: &random).rounded(),
                            height: Double.random(in: 50...6000, using: &random).rounded())
        var size = CGSize(width: 1280, height: 800)
        var t = CanvasTransform.fitted(source: source, viewport: size, backingScale: 1, trailingReserve: 64)
        for _ in 0..<3 {
            let next = CGSize(width: Double.random(in: 300...2600, using: &random).rounded(),
                              height: Double.random(in: 300...1600, using: &random).rounded())
            t.viewportChanged(source: source, from: size, to: next, backingScale: 1, mode: .fit, trailingReserve: 64)
            size = next
        }
        let expected = CanvasTransform.fitted(source: source, viewport: size, backingScale: 1, trailingReserve: 64)
        #expect(t.zoom == expected.zoom && t.origin == expected.origin, "seed \(seed)")
    }
}

@Test(.timeLimit(.minutes(2))) func viewportChangedOutsideFitModeIgnoresReserve() {
    let start = CanvasTransform(backingScale: 1, zoom: 1, origin: CGPoint(x: -100, y: -200))
    var withReserve = start, without = start
    let larger = CGSize(width: 1440, height: 900)
    withReserve.viewportChanged(source: page39Image, from: page39Window, to: larger, backingScale: 1,
                                mode: .actualPixels, trailingReserve: 64)
    without.viewportChanged(source: page39Image, from: page39Window, to: larger, backingScale: 1,
                            mode: .actualPixels, trailingReserve: 0)
    #expect(withReserve.zoom == without.zoom && withReserve.origin == without.origin)
}

// MARK: - B7: the fixed mark paint

@Test(.timeLimit(.minutes(2))) func annotationStyleIsFixedPage39Red() {
    let style = AnnotationStyle.default
    #expect(style.red == 220.0 / 255 && style.green == 38.0 / 255 && style.blue == 38.0 / 255)
    #expect(AnnotationStyle.screenLineWidth == 3)
}

@Test(.timeLimit(.minutes(2))) func annotationLineWidthAtZoom032() {
    let style = AnnotationStyle.forScreen(pointsPerImagePixel: 0.32)
    #expect(abs(style.lineWidth - 9.375) < 1e-9)
    #expect(style.red == AnnotationStyle.default.red && style.green == AnnotationStyle.default.green
        && style.blue == AnnotationStyle.default.blue)
}

@Test(.timeLimit(.minutes(2))) func annotationLineWidthScreenConstantProperty() {
    for seed in UInt64(1)...300 {
        var random = GeometryRandom(seed: seed)
        let scale = Double.random(in: 0.01...8, using: &random)
        #expect(abs(AnnotationStyle.forScreen(pointsPerImagePixel: scale).lineWidth * scale - 3) < 1e-9, "seed \(seed)")
    }
}

// MARK: - Drag, hit test, nudge

/// The page-39 placement: zoom 0.32 at (352, 16).
private let page39Transform = CanvasTransform.fitted(source: page39Image, viewport: page39Window, backingScale: 1,
                                                     trailingReserve: 64)
private let fixedTransform = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))

@Test(.timeLimit(.minutes(2))) func dragRectConvertsViewToImagePixels() {
    let rect = AnnotationGeometry.rect(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300),
                                       transform: fixedTransform, imageSize: page39Image)
    #expect(rect.map { near($0, CGRect(x: 150, y: 575, width: 312.5, height: 312.5), 1e-6) } == true)
}

@Test(.timeLimit(.minutes(2))) func dragRectClampedToImage() {
    let far = AnnotationGeometry.rect(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 1000, y: 900),
                                      transform: fixedTransform, imageSize: page39Image)
    #expect(far.map { near($0, CGRect(x: 150, y: 575, width: 1450, height: 1825), 1e-6) } == true)
    let before = AnnotationGeometry.rect(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 400, y: 300),
                                         transform: fixedTransform, imageSize: page39Image)
    #expect(before?.minX == 0 && before?.minY == 0)
    #expect(before.map { abs($0.maxX - 150) < 1e-6 && abs($0.maxY - 887.5) < 1e-6 } == true)
}

@Test(.timeLimit(.minutes(2))) func dragRectEntirelyOutsideImageIsNil() {
    #expect(AnnotationGeometry.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 12 + 100),
                                    transform: fixedTransform, imageSize: page39Image) == nil)
}

@Test(.timeLimit(.minutes(2))) func dragBelowMinimumIsNil() {
    let m = AnnotationGeometry.minimumDrag
    #expect(m > 0)
    let start = CGPoint(x: 600, y: 300)
    func drag(_ dx: CGFloat, _ dy: CGFloat) -> CGRect? {
        AnnotationGeometry.rect(from: start, to: CGPoint(x: start.x + dx, y: start.y + dy),
                                transform: fixedTransform, imageSize: page39Image)
    }
    #expect(drag(m - 0.01, m - 0.01) == nil)
    #expect(drag(m, m) != nil)
    #expect(drag(200, m - 0.01) == nil)
    #expect(drag(-(m - 0.01), 200) == nil)
}

@Test(.timeLimit(.minutes(2))) func dragRectSymmetricAndInsideProperty() {
    let bounds = CGRect(origin: .zero, size: page39Image)
    for seed in UInt64(1)...400 {
        var random = GeometryRandom(seed: seed)
        let a = CGPoint(x: Double.random(in: -200...1500, using: &random), y: Double.random(in: -200...1500, using: &random))
        let b = CGPoint(x: Double.random(in: -200...1500, using: &random), y: Double.random(in: -200...1500, using: &random))
        let forward = AnnotationGeometry.rect(from: a, to: b, transform: fixedTransform, imageSize: page39Image)
        let backward = AnnotationGeometry.rect(from: b, to: a, transform: fixedTransform, imageSize: page39Image)
        #expect(forward == backward, "seed \(seed)")
        if let forward {
            #expect(bounds.contains(forward) && forward.width > 0 && forward.height > 0, "seed \(seed)")
        }
    }
}

private func mark(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, width: Double = 4) -> AnnotationMark {
    var style = AnnotationStyle.default
    style.lineWidth = width
    return AnnotationMark(rect: CGRect(x: x, y: y, width: w, height: h), style: style)
}

@Test(.timeLimit(.minutes(2))) func hitTestTopmostFirst() {
    let marks = [mark(100, 100, 400, 400), mark(300, 300, 400, 400)]
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 350, y: 350), marks: marks) == 1)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 150, y: 150), marks: marks) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 1000, y: 1000), marks: marks) == nil)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 350, y: 350), marks: []) == nil)
}

@Test(.timeLimit(.minutes(2))) func hitTestOutsideStrokeTolerance() {
    let marks = [mark(100, 100, 400, 400, width: 10)]
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 500 + 5 + 1, y: 300), marks: marks) == nil)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 500 + 5 - 0.5, y: 300), marks: marks) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 300, y: 100 - 5 - 1), marks: marks) == nil)
}

@Test(.timeLimit(.minutes(2))) func nudgeSteps() {
    let rect = CGRect(x: 100, y: 100, width: 50, height: 50)
    #expect(AnnotationGeometry.nudge(rect, dx: 1, dy: 0, imageSize: page39Image).origin == CGPoint(x: 101, y: 100))
    #expect(AnnotationGeometry.nudge(rect, dx: -10, dy: 0, imageSize: page39Image).origin == CGPoint(x: 90, y: 100))
    #expect(AnnotationGeometry.nudge(rect, dx: 0, dy: 1, imageSize: page39Image).origin == CGPoint(x: 100, y: 101))
    #expect(AnnotationGeometry.nudge(rect, dx: 0, dy: -10, imageSize: page39Image).origin == CGPoint(x: 100, y: 90))
    #expect(AnnotationGeometry.nudge(rect, dx: 1, dy: 0, imageSize: page39Image).size == rect.size)
}

@Test(.timeLimit(.minutes(2))) func nudgeClampsAtImageEdge() {
    let left = CGRect(x: 0, y: 20, width: 30, height: 40)
    #expect(AnnotationGeometry.nudge(left, dx: -1, dy: 0, imageSize: page39Image) == left)
    let right = CGRect(x: 1570, y: 20, width: 30, height: 40)
    #expect(AnnotationGeometry.nudge(right, dx: 10, dy: 0, imageSize: page39Image) == right)
    let bottom = CGRect(x: 10, y: 2395, width: 30, height: 5)
    #expect(AnnotationGeometry.nudge(bottom, dx: 0, dy: 10, imageSize: page39Image) == bottom)
    let nearEdge = CGRect(x: 5, y: 20, width: 30, height: 40)
    #expect(AnnotationGeometry.nudge(nearEdge, dx: -10, dy: 0, imageSize: page39Image).minX == 0)
}

@Test(.timeLimit(.minutes(2))) func nudgeRoundTripProperty() {
    for seed in UInt64(1)...300 {
        var random = GeometryRandom(seed: seed)
        let start = CGRect(x: Double(Int.random(in: 200...1200, using: &random)),
                           y: Double(Int.random(in: 200...2000, using: &random)), width: 100, height: 100)
        let steps = (0..<Int.random(in: 1...8, using: &random)).map { _ in
            (Bool.random(using: &random) ? 1 : 10) * (Bool.random(using: &random) ? 1 : -1)
        }
        let axes = steps.map { _ in Bool.random(using: &random) }
        var rect = start
        for (step, horizontal) in zip(steps, axes) {
            rect = AnnotationGeometry.nudge(rect, dx: horizontal ? step : 0, dy: horizontal ? 0 : step, imageSize: page39Image)
        }
        for (step, horizontal) in zip(steps, axes).reversed() {
            rect = AnnotationGeometry.nudge(rect, dx: horizontal ? -step : 0, dy: horizontal ? 0 : -step, imageSize: page39Image)
        }
        #expect(rect == start, "seed \(seed)")
    }
}
