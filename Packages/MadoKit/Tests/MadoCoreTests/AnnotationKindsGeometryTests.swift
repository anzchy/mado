import CoreGraphics
import Foundation
import Testing
import MadoCore

// #692 (P7-11) WI-1: the arrow, pen, highlighter, step and text marks — drawing from a drag, hit testing, moving,
// resizing with handles, and step numbering. Expected values are computed by hand from page 39 (annotate.html).

private let image = CGSize(width: 1600, height: 2400)
/// Page 39's placement: 1600×2400 at zoom 0.32, origin (352, 16).
private let page39 = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
private let screen = AnnotationStyle.forScreen(pointsPerImagePixel: 0.32)
private let unit = AnnotationStyle.default

private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}
private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}
/// The sample at `i`, or a far point when there is none (no trap on a short array).
private func at(_ points: [CGPoint], _ i: Int) -> CGPoint { points.indices.contains(i) ? points[i] : CGPoint(x: -1e9, y: -1e9) }
private func length(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }
/// view (x, y) → image pixels on page 39: ((x − 352) / 0.32, (y − 16) / 0.32), worked out by hand.
private func px(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 352) / 0.32, y: (y - 16) / 0.32) }

// MARK: - Arrow (G1–G5)

@Test(.timeLimit(.minutes(2))) func issue692ArrowDragStoresBothEndsInImagePixels() throws {
    let mark = try #require(AnnotationGeometry.arrow(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 500, y: 336),
                                                     transform: page39, imageSize: image, style: screen))
    #expect(mark.kind == .arrow)
    #expect(mark.points.count == 2)
    #expect(near(at(mark.points, 0), CGPoint(x: 150, y: 1200)))
    #expect(near(at(mark.points, 1), CGPoint(x: 462.5, y: 1000)))
    #expect(near(mark.rect, CGRect(x: 150, y: 1000, width: 312.5, height: 200)))
    #expect(abs(mark.style.lineWidth - 9.375) < 1e-9, "3 pt on screen at 0.32 pt per pixel")
}

@Test(.timeLimit(.minutes(2))) func issue692ArrowTooShortAddsNothing() {
    for end in [CGPoint(x: 400, y: 400), CGPoint(x: 403, y: 402), CGPoint(x: 402, y: 397)] {
        #expect(AnnotationGeometry.arrow(from: CGPoint(x: 400, y: 400), to: end, transform: page39, imageSize: image,
                                         style: screen) == nil, "\(end)")
    }
    // 4 pt along one axis is long enough.
    #expect(AnnotationGeometry.arrow(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 404, y: 400), transform: page39,
                                     imageSize: image, style: screen) != nil)
}

@Test(.timeLimit(.minutes(2))) func issue692ArrowEndsClampToTheImage() throws {
    // From inside to beyond the right and bottom edges (the image ends at x 864, y 784 on screen).
    let mark = try #require(AnnotationGeometry.arrow(from: CGPoint(x: 800, y: 700), to: CGPoint(x: 1000, y: 900),
                                                     transform: page39, imageSize: image, style: screen))
    #expect(near(at(mark.points, 0), px(800, 700)))
    #expect(near(at(mark.points, 1), CGPoint(x: 1600, y: 2400)))
    #expect(mark.rect.maxX <= 1600 && mark.rect.maxY <= 2400)
}

@Test(.timeLimit(.minutes(2))) func issue692ArrowHeadMatchesPage39() {
    // Page 39: shaft M446 640 L492 572, head M479 576 L492 572 L495 586, stroke 3.
    let tail = CGPoint(x: 446, y: 640), tip = CGPoint(x: 492, y: 572)
    let (a, b) = AnnotationGeometry.arrowHead(tail: tail, tip: tip, lineWidth: 3)
    let arms = [a, b].sorted { $0.x < $1.x }
    #expect(near(arms[0], CGPoint(x: 479, y: 576), 1.5), "\(arms[0])")
    #expect(near(arms[1], CGPoint(x: 495, y: 586), 1.5), "\(arms[1])")
    #expect(abs(length(tip, a) - 14) < 0.01 && abs(length(tip, b) - 14) < 0.01)
    // Symmetric about the shaft: both arms make the same angle with it.
    let back = CGVector(dx: tail.x - tip.x, dy: tail.y - tip.y)
    func angle(_ p: CGPoint) -> Double {
        let v = CGVector(dx: p.x - tip.x, dy: p.y - tip.y)
        return acos((v.dx * back.dx + v.dy * back.dy) / (hypot(v.dx, v.dy) * hypot(back.dx, back.dy))) * 180 / .pi
    }
    #expect(abs(angle(a) - 42) < 0.01 && abs(angle(b) - 42) < 0.01)
}

@Test(.timeLimit(.minutes(2))) func issue692ArrowHeadScalesWithTheStroke() {
    let tip = CGPoint(x: 100, y: 0)
    let (a, b) = AnnotationGeometry.arrowHead(tail: .zero, tip: tip, lineWidth: 6)
    #expect(abs(length(tip, a) - 28) < 0.01 && abs(length(tip, b) - 28) < 0.01)
    // Pointing right, the arms go back to the left, one above and one below the shaft.
    #expect(a.x < 100 && b.x < 100 && (a.y < 0) != (b.y < 0))
}

// MARK: - Pen and highlighter (G6)

@Test(.timeLimit(.minutes(2))) func issue692StrokeKeepsEverySample() throws {
    let samples = [CGPoint(x: 400, y: 400), CGPoint(x: 401, y: 401), CGPoint(x: 405, y: 400), CGPoint(x: 410, y: 404)]
    for kind in [AnnotationKind.pen, .highlighter] {
        let mark = try #require(AnnotationGeometry.stroke(kind, through: samples, transform: page39, imageSize: image,
                                                          style: screen))
        #expect(mark.kind == kind)
        #expect(mark.points.count == 4, "no simplification")
        #expect(near(at(mark.points, 1), px(401, 401)))
        #expect(near(mark.rect, CGRect(x: 150, y: 1200, width: 31.25, height: 12.5)))
    }
}

@Test(.timeLimit(.minutes(2))) func issue692StrokeTooSmallAddsNothing() {
    let dot = [CGPoint(x: 400, y: 400)]
    let wobble = [CGPoint(x: 400, y: 400), CGPoint(x: 403, y: 402), CGPoint(x: 401, y: 403)]
    for kind in [AnnotationKind.pen, .highlighter] {
        #expect(AnnotationGeometry.stroke(kind, through: dot, transform: page39, imageSize: image, style: screen) == nil)
        #expect(AnnotationGeometry.stroke(kind, through: wobble, transform: page39, imageSize: image, style: screen) == nil)
        #expect(AnnotationGeometry.stroke(kind, through: [], transform: page39, imageSize: image, style: screen) == nil)
    }
}

@Test(.timeLimit(.minutes(2))) func issue692StrokeClampsSamplesToTheImage() throws {
    let mark = try #require(AnnotationGeometry.stroke(.pen, through: [CGPoint(x: 300, y: 400), CGPoint(x: 400, y: 400)],
                                                      transform: page39, imageSize: image, style: screen))
    #expect(near(at(mark.points, 0), CGPoint(x: 0, y: 1200)))
}

// MARK: - Step markers (G7, G8)

@Test(.timeLimit(.minutes(2))) func issue692StepIsA28PointDiscAtTheClick() {
    let mark = AnnotationGeometry.step(at: CGPoint(x: 400, y: 400), transform: page39, imageSize: image, style: screen)
    #expect(mark.kind == .step)
    #expect(near(at(mark.points, 0), CGPoint(x: 150, y: 1200)))
    // 28 pt at 0.32 pt per pixel = 87.5 px.
    #expect(near(mark.rect, CGRect(x: 150 - 43.75, y: 1200 - 43.75, width: 87.5, height: 87.5)))
}

@Test(.timeLimit(.minutes(2))) func issue692StepStaysInsideTheImage() {
    let mark = AnnotationGeometry.step(at: CGPoint(x: 353, y: 17), transform: page39, imageSize: image, style: screen)
    #expect(near(mark.rect.origin, .zero))
    #expect(near(at(mark.points, 0), CGPoint(x: 43.75, y: 43.75)))
}

@Test(.timeLimit(.minutes(2))) func issue692StepNumbersFollowCreationOrder() {
    let s = AnnotationMark.step(centre: CGPoint(x: 50, y: 50))
    let marks = [s, AnnotationMark(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), s,
                 AnnotationMark.arrow(tail: .zero, tip: CGPoint(x: 9, y: 9)), s]
    #expect(AnnotationGeometry.stepNumbers(marks) == [1, nil, 2, nil, 3])
    #expect(AnnotationGeometry.stepNumbers([]) == [])
}

// MARK: - Constructors

@Test(.timeLimit(.minutes(2))) func issue692ConstructorsDeriveBounds() {
    let arrow = AnnotationMark.arrow(tail: CGPoint(x: 30, y: 10), tip: CGPoint(x: 10, y: 40))
    #expect(arrow.points == [CGPoint(x: 30, y: 10), CGPoint(x: 10, y: 40)])
    #expect(arrow.rect == CGRect(x: 10, y: 10, width: 20, height: 30))
    let pen = AnnotationMark.stroke(.pen, points: [CGPoint(x: 5, y: 9), CGPoint(x: 1, y: 2), CGPoint(x: 7, y: 4)])
    #expect(pen.kind == .pen && pen.rect == CGRect(x: 1, y: 2, width: 6, height: 7))
    let text = AnnotationMark.text("Hi", origin: CGPoint(x: 4, y: 5), size: CGSize(width: 20, height: 22), style: unit)
    #expect(text.kind == .text && text.text == "Hi" && text.points == [CGPoint(x: 4, y: 5)])
    #expect(text.rect == CGRect(x: 4, y: 5, width: 20, height: 22))
    let step = AnnotationMark.step(centre: CGPoint(x: 100, y: 100), style: unit)
    #expect(step.rect == CGRect(x: 86, y: 86, width: 28, height: 28))
    #expect(AnnotationMetrics.drawnWidth(AnnotationMark.stroke(.highlighter, points: [.zero], style: screen)) == 14 / 0.32)
    #expect(AnnotationMetrics.drawnWidth(pen) == 3)
}

// MARK: - Hit test (G9–G11)

@Test(.timeLimit(.minutes(2))) func issue692HitTestArrowFollowsTheShaft() {
    let arrow = AnnotationMark.arrow(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 100), style: unit)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 50), marks: [arrow]) == 0)
    // Inside the bounds, but 10 px off the shaft (distance 7.07 · √2 = 10).
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 57.07, y: 42.93), marks: [arrow]) == nil)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 90, y: 10), marks: [arrow]) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue692HitTestStrokeIsNotABox() {
    let pen = AnnotationMark.stroke(.pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)],
                                    style: unit)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 1), marks: [pen]) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 99, y: 60), marks: [pen]) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 30, y: 70), marks: [pen]) == nil, "inside the bounds, far from the path")
    // The highlighter is 14 px wide at unit 1: 8 px off its centre line still hits, 20 px does not.
    let highlighter = AnnotationMark.stroke(.highlighter, points: [CGPoint(x: 0, y: 200), CGPoint(x: 100, y: 200)],
                                            style: unit)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 208), marks: [highlighter]) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 220), marks: [highlighter]) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue692HitTestTextAndStepAndTopmost() {
    let text = AnnotationMark.text("Hi", origin: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 22), style: unit)
    let step = AnnotationMark.step(centre: CGPoint(x: 40, y: 20), style: unit)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 12, y: 30), marks: [text]) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 70, y: 30), marks: [text]) == nil)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 40, y: 20), marks: [text, step]) == 1, "topmost wins")
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 40, y: 20), marks: [step, text]) == 1)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 80, y: 20), marks: [step]) == nil)
}

// MARK: - Move (G12)

@Test(.timeLimit(.minutes(2))) func issue692TranslateMovesPointsAndBounds() {
    let arrow = AnnotationMark.arrow(tail: CGPoint(x: 100, y: 100), tip: CGPoint(x: 200, y: 150), style: unit)
    let moved = AnnotationGeometry.translate(arrow, by: CGVector(dx: 10, dy: -5), imageSize: image)
    #expect(moved.points == [CGPoint(x: 110, y: 95), CGPoint(x: 210, y: 145)])
    #expect(moved.rect == CGRect(x: 110, y: 95, width: 100, height: 50))
    // Near the top-left edge the move is clamped and the shape keeps its size.
    let clamped = AnnotationGeometry.translate(arrow, by: CGVector(dx: -500, dy: -120), imageSize: image)
    #expect(clamped.points == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)])
    let far = AnnotationGeometry.translate(arrow, by: CGVector(dx: 5000, dy: 5000), imageSize: image)
    #expect(far.rect == CGRect(x: 1500, y: 2350, width: 100, height: 50))
    let text = AnnotationMark.text("A", origin: CGPoint(x: 5, y: 5), size: CGSize(width: 10, height: 20), style: unit)
    let movedText = AnnotationGeometry.translate(text, by: CGVector(dx: 3, dy: 4), imageSize: image)
    #expect(movedText.points == [CGPoint(x: 8, y: 9)] && movedText.rect.origin == CGPoint(x: 8, y: 9))
    #expect(movedText.text == "A" && movedText.kind == .text)
    let rect = AnnotationMark(rect: CGRect(x: 10, y: 10, width: 20, height: 20))
    #expect(AnnotationGeometry.translate(rect, by: CGVector(dx: 1, dy: 2), imageSize: image).rect
            == CGRect(x: 11, y: 12, width: 20, height: 20))
}

// MARK: - Handles and resize (G13–G17)

@Test(.timeLimit(.minutes(2))) func issue692HandlesPerKind() {
    let box: [AnnotationHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
    #expect(AnnotationGeometry.handles(for: .rectangle) == box)
    #expect(AnnotationGeometry.handles(for: .highlighter) == box)
    #expect(AnnotationGeometry.handles(for: .pen) == box)
    #expect(AnnotationGeometry.handles(for: .arrow) == [.tail, .tip])
    #expect(AnnotationGeometry.handles(for: .text) == [])
    #expect(AnnotationGeometry.handles(for: .step) == [])
    let rect = AnnotationMark(rect: CGRect(x: 10, y: 20, width: 100, height: 50))
    #expect(AnnotationGeometry.handlePoint(.topLeft, of: rect) == CGPoint(x: 10, y: 20))
    #expect(AnnotationGeometry.handlePoint(.top, of: rect) == CGPoint(x: 60, y: 20))
    #expect(AnnotationGeometry.handlePoint(.right, of: rect) == CGPoint(x: 110, y: 45))
    #expect(AnnotationGeometry.handlePoint(.bottomLeft, of: rect) == CGPoint(x: 10, y: 70))
    let arrow = AnnotationMark.arrow(tail: CGPoint(x: 1, y: 2), tip: CGPoint(x: 30, y: 40))
    #expect(AnnotationGeometry.handlePoint(.tail, of: arrow) == CGPoint(x: 1, y: 2))
    #expect(AnnotationGeometry.handlePoint(.tip, of: arrow) == CGPoint(x: 30, y: 40))
}

@Test(.timeLimit(.minutes(2))) func issue692ResizeRectangleByEveryHandle() {
    let rect = AnnotationMark(rect: CGRect(x: 100, y: 100, width: 100, height: 100))
    func resized(_ h: AnnotationHandle, _ x: CGFloat, _ y: CGFloat) -> CGRect {
        AnnotationGeometry.resize(rect, handle: h, to: CGPoint(x: x, y: y), imageSize: image).rect
    }
    #expect(resized(.bottomRight, 250, 300) == CGRect(x: 100, y: 100, width: 150, height: 200))
    #expect(resized(.topLeft, 50, 80) == CGRect(x: 50, y: 80, width: 150, height: 120))
    #expect(resized(.top, 999, 150) == CGRect(x: 100, y: 150, width: 100, height: 50), "an edge handle moves one side")
    #expect(resized(.left, 120, 999) == CGRect(x: 120, y: 100, width: 80, height: 100))
    #expect(resized(.right, 300, -5) == CGRect(x: 100, y: 100, width: 200, height: 100))
    #expect(resized(.bottom, 0, 130) == CGRect(x: 100, y: 100, width: 100, height: 30))
    #expect(resized(.topRight, 180, 60) == CGRect(x: 100, y: 60, width: 80, height: 140))
    #expect(resized(.bottomLeft, 90, 210) == CGRect(x: 90, y: 100, width: 110, height: 110))
    // Dragged past the opposite corner the rectangle flips round, never a negative size.
    #expect(resized(.bottomRight, 40, 60) == CGRect(x: 40, y: 60, width: 60, height: 40))
    // Clamped to the image.
    #expect(resized(.bottomRight, 5000, 5000) == CGRect(x: 100, y: 100, width: 1500, height: 2300))
    // Handles that a rectangle does not have change nothing.
    #expect(resized(.tip, 0, 0) == rect.rect)
}

@Test(.timeLimit(.minutes(2))) func issue692ResizeStrokeScalesItsSamples() {
    let pen = AnnotationMark.stroke(.pen, points: [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 120), CGPoint(x: 200, y: 140)],
                                    style: unit)
    let wider = AnnotationGeometry.resize(pen, handle: .right, to: CGPoint(x: 300, y: 0), imageSize: image)
    #expect(wider.points == [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 120), CGPoint(x: 300, y: 140)])
    #expect(wider.rect == CGRect(x: 100, y: 100, width: 200, height: 40))
    let taller = AnnotationGeometry.resize(pen, handle: .top, to: CGPoint(x: 0, y: 60), imageSize: image)
    #expect(taller.points == [CGPoint(x: 100, y: 60), CGPoint(x: 150, y: 100), CGPoint(x: 200, y: 140)])
    // A flat (horizontal) stroke keeps its samples' y when only the width changes.
    let flat = AnnotationMark.stroke(.highlighter, points: [CGPoint(x: 0, y: 50), CGPoint(x: 10, y: 50)], style: unit)
    let longer = AnnotationGeometry.resize(flat, handle: .bottomRight, to: CGPoint(x: 20, y: 80), imageSize: image)
    #expect(longer.points == [CGPoint(x: 0, y: 50), CGPoint(x: 20, y: 50)], "a zero extent keeps its axis")
    #expect(longer.kind == .highlighter && longer.style == unit)
    // G15b: a highlighter scales like the pen and keeps its style.
    let marker = AnnotationMark.stroke(.highlighter, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 140)], style: unit)
    let scaled = AnnotationGeometry.resize(marker, handle: .bottomRight, to: CGPoint(x: 300, y: 180), imageSize: image)
    #expect(scaled.points == [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 180)] && scaled.style == unit)
}

@Test(.timeLimit(.minutes(2))) func issue692ResizeArrowMovesOneEnd() {
    let arrow = AnnotationMark.arrow(tail: CGPoint(x: 10, y: 10), tip: CGPoint(x: 100, y: 50), style: unit)
    let tip = AnnotationGeometry.resize(arrow, handle: .tip, to: CGPoint(x: 200, y: 5), imageSize: image)
    #expect(tip.points == [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 5)])
    #expect(tip.rect == CGRect(x: 10, y: 5, width: 190, height: 5))
    let tail = AnnotationGeometry.resize(arrow, handle: .tail, to: CGPoint(x: -40, y: 3000), imageSize: image)
    #expect(tail.points == [CGPoint(x: 0, y: 2400), CGPoint(x: 100, y: 50)], "clamped to the image")
    #expect(AnnotationGeometry.resize(arrow, handle: .topLeft, to: .zero, imageSize: image) == arrow)
    // G16b: the tail handle moves only the tail.
    let moved = AnnotationGeometry.resize(arrow, handle: .tail, to: CGPoint(x: 20, y: 30), imageSize: image)
    #expect(moved.points == [CGPoint(x: 20, y: 30), CGPoint(x: 100, y: 50)])
    #expect(moved.rect == CGRect(x: 20, y: 30, width: 80, height: 20))
}

@Test(.timeLimit(.minutes(2))) func issue692TextAndStepOnlyMove() {
    let text = AnnotationMark.text("Hi", origin: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 22), style: unit)
    let step = AnnotationMark.step(centre: CGPoint(x: 100, y: 100), style: unit)
    for handle in AnnotationHandle.allCases {
        #expect(AnnotationGeometry.resize(text, handle: handle, to: CGPoint(x: 500, y: 500), imageSize: image) == text)
        #expect(AnnotationGeometry.resize(step, handle: handle, to: CGPoint(x: 500, y: 500), imageSize: image) == step)
    }
}
