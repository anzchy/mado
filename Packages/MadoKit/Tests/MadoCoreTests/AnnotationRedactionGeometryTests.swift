import CoreGraphics
import Testing
@testable import MadoCore

// #693 slice B (P7-11) WI-1: the redaction mark and the crop drag (tests-20261114-i693b.md M1–M3).

private let page39 = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
private let image = CGSize(width: 1600, height: 2400)

@Test func issue693RedactionMarkHasItsStyleAndRect() {
    let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
    for style: RedactionStyle in [.solid, .mosaic(strength: 24)] {
        let mark = AnnotationMark.redaction(rect: rect, style: style)
        #expect(mark.kind == .redaction)
        #expect(mark.redaction == style)
        #expect(mark.rect == rect)
        #expect(mark.points.isEmpty && mark.text.isEmpty)
    }
    #expect(AnnotationMark(rect: rect).redaction == nil)
    #expect(AnnotationMark.step(centre: CGPoint(x: 50, y: 50)).redaction == nil)
    #expect(AnnotationMark.arrow(tail: .zero, tip: CGPoint(x: 9, y: 9)).redaction == nil)
}

@Test func issue693RedactionGeometryIsTheRectangles() {
    let rect = CGRect(x: 100, y: 100, width: 200, height: 80)
    let redaction = AnnotationMark.redaction(rect: rect, style: .solid)
    let rectangle = AnnotationMark(rect: rect)
    // Hit inside and on the grown edge, miss outside.
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 200, y: 140), marks: [redaction]) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 99, y: 140), marks: [redaction]) == 0)
    #expect(AnnotationGeometry.hitTest(CGPoint(x: 90, y: 140), marks: [redaction]) == nil)
    // The rectangle's eight handles, and the rectangle's resize.
    #expect(AnnotationGeometry.handles(for: .redaction) == AnnotationGeometry.handles(for: .rectangle))
    #expect(AnnotationGeometry.handles(for: .redaction).count == 8)
    let resized = AnnotationGeometry.resize(redaction, handle: .bottomRight, to: CGPoint(x: 400, y: 300), imageSize: image)
    #expect(resized.rect == AnnotationGeometry.resize(rectangle, handle: .bottomRight, to: CGPoint(x: 400, y: 300),
                                                      imageSize: image).rect)
    #expect(resized.rect == CGRect(x: 100, y: 100, width: 300, height: 200))
    #expect(resized.kind == .redaction && resized.redaction == .solid)
    // Moving keeps it inside the image.
    let moved = AnnotationGeometry.translate(redaction, by: CGVector(dx: 5000, dy: -5000), imageSize: image)
    #expect(moved.rect == CGRect(x: 1400, y: 0, width: 200, height: 80))
    #expect(moved.redaction == .solid)
}

@Test func issue693CropRectIsPixelAlignedAndClamped() throws {
    // View (352.1, 16.2) → image (0.3125, 0.625); view (500.5, 300.7) → image (464.0625, 889.6875).
    let crop = try #require(AnnotationGeometry.cropRect(from: CGPoint(x: 352.1, y: 16.2), to: CGPoint(x: 500.5, y: 300.7),
                                                        transform: page39, imageSize: image))
    #expect(crop == CGRect(x: 0, y: 1, width: 464, height: 889))
    // Either drag direction gives the same crop.
    #expect(AnnotationGeometry.cropRect(from: CGPoint(x: 500.5, y: 300.7), to: CGPoint(x: 352.1, y: 16.2),
                                        transform: page39, imageSize: image) == crop)
    // Past the image edges it clamps to the image.
    let all = try #require(AnnotationGeometry.cropRect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 2000, y: 2000),
                                                       transform: page39, imageSize: image))
    #expect(all == CGRect(origin: .zero, size: image))
    // Too short a drag, or a drag wholly outside the image, sets nothing.
    #expect(AnnotationGeometry.cropRect(from: CGPoint(x: 400, y: 100), to: CGPoint(x: 402, y: 300),
                                        transform: page39, imageSize: image) == nil)
    #expect(AnnotationGeometry.cropRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300),
                                        transform: page39, imageSize: image) == nil)
    // A sliver narrower than a pixel at a high zoom still covers at least one whole pixel.
    let close = CanvasTransform(backingScale: 1, zoom: 40, origin: .zero)
    let one = try #require(AnnotationGeometry.cropRect(from: CGPoint(x: 405, y: 405), to: CGPoint(x: 410, y: 410),
                                                       transform: close, imageSize: image))
    #expect(one == CGRect(x: 10, y: 10, width: 1, height: 1))
}
