import CoreGraphics

/// #690: pointer and key geometry for marks. View points are top-left; marks are in upright image pixels.
public enum AnnotationGeometry {
    /// A drag shorter than this on either axis (view points) adds no mark.
    public static let minimumDrag: CGFloat = 4

    /// The image-pixel rectangle a drag from `a` to `b` (view points) draws, clamped to the image; nil when it
    /// is too small or lies outside the image.
    public static func rect(from a: CGPoint, to b: CGPoint, transform: CanvasTransform, imageSize: CGSize) -> CGRect? {
        guard abs(b.x - a.x) >= minimumDrag, abs(b.y - a.y) >= minimumDrag else { return nil }
        let low = transform.viewToImage(CGPoint(x: min(a.x, b.x), y: min(a.y, b.y)))
        let high = transform.viewToImage(CGPoint(x: max(a.x, b.x), y: max(a.y, b.y)))
        let drawn = CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
        let clamped = drawn.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    /// #693: the crop a drag from `a` to `b` (view points) sets: its edges rounded to whole image pixels and clamped
    /// to the image; nil when the drag is too small or leaves no pixel.
    public static func cropRect(from a: CGPoint, to b: CGPoint, transform: CanvasTransform, imageSize: CGSize) -> CGRect? {
        guard let drawn = rect(from: a, to: b, transform: transform, imageSize: imageSize) else { return nil }
        func edges(_ low: CGFloat, _ high: CGFloat, _ size: CGFloat) -> (CGFloat, CGFloat) {
            var low = low.rounded(), high = high.rounded()
            if high - low < 1 {
                high = min(low + 1, size)
                low = high - 1
            }
            return (low, high)
        }
        let x = edges(drawn.minX, drawn.maxX, imageSize.width), y = edges(drawn.minY, drawn.maxY, imageSize.height)
        return CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
    }

    /// The topmost mark under `point` (image pixels): a rectangle, text or step by its box grown by half the stroke;
    /// an arrow, pen or highlighter by its path, within half its drawn width plus one stroke (#692).
    public static func hitTest(_ point: CGPoint, marks: [AnnotationMark]) -> Int? {
        marks.indices.last { hits(point, marks[$0]) }
    }

    private static func hits(_ point: CGPoint, _ mark: AnnotationMark) -> Bool {
        switch mark.kind {
        case .rectangle, .text, .step, .redaction:
            let half = mark.style.lineWidth / 2
            return mark.rect.insetBy(dx: -half, dy: -half).contains(point)
        case .arrow, .pen, .highlighter:
            let reach = AnnotationMetrics.drawnWidth(mark) / 2 + mark.style.lineWidth
            guard let first = mark.points.first else { return false }
            if mark.points.count == 1 { return distance(point, first, first) <= reach }
            return zip(mark.points, mark.points.dropFirst()).contains { distance(point, $0, $1) <= reach }
        }
    }

    /// The distance from `p` to the segment `a`–`b`.
    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let squared = dx * dx + dy * dy
        let t = squared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// #692: a handle of the selected mark. Rectangles, highlighter and pen strokes have the eight box handles; an arrow
/// has its two ends; text and step markers only move.
public enum AnnotationHandle: Hashable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, tail, tip
}

/// #692: the other mark kinds, moving and resizing, and step numbering.
extension AnnotationGeometry {
    /// An arrow from `a` to `b` (view points), both ends clamped to the image; nil for a drag under `minimumDrag`.
    public static func arrow(from a: CGPoint, to b: CGPoint, transform: CanvasTransform, imageSize: CGSize,
                             style: AnnotationStyle) -> AnnotationMark? {
        guard max(abs(b.x - a.x), abs(b.y - a.y)) >= minimumDrag else { return nil }
        return .arrow(tail: clamp(transform.viewToImage(a), imageSize), tip: clamp(transform.viewToImage(b), imageSize),
                      style: style)
    }

    /// A pen or highlighter stroke through every sample (view points), clamped to the image; nil when the samples
    /// span less than `minimumDrag` on both axes.
    public static func stroke(_ kind: AnnotationKind, through viewPoints: [CGPoint], transform: CanvasTransform,
                              imageSize: CGSize, style: AnnotationStyle) -> AnnotationMark? {
        let span = AnnotationMark.bounds(viewPoints)
        guard !viewPoints.isEmpty, max(span.width, span.height) >= minimumDrag else { return nil }
        return .stroke(kind, points: viewPoints.map { clamp(transform.viewToImage($0), imageSize) }, style: style)
    }

    /// A step marker centred on `point` (view points), kept inside the image.
    public static func step(at point: CGPoint, transform: CanvasTransform, imageSize: CGSize,
                            style: AnnotationStyle) -> AnnotationMark {
        let marker = AnnotationMark.step(centre: transform.viewToImage(point), style: style)
        return translate(marker, by: .zero, imageSize: imageSize)
    }

    /// The ends of the two head arms of an arrow (image pixels).
    public static func arrowHead(tail: CGPoint, tip: CGPoint, lineWidth: Double) -> (CGPoint, CGPoint) {
        let length = AnnotationMetrics.arrowHeadLength * lineWidth / AnnotationStyle.screenLineWidth
        let back = atan2(tail.y - tip.y, tail.x - tip.x)
        let spread = AnnotationMetrics.arrowHeadAngleDegrees * .pi / 180
        func arm(_ angle: Double) -> CGPoint { CGPoint(x: tip.x + length * cos(angle), y: tip.y + length * sin(angle)) }
        return (arm(back + spread), arm(back - spread))
    }

    /// Each step marker's number: 1 + the step markers before it; nil for other kinds.
    public static func stepNumbers(_ marks: [AnnotationMark]) -> [Int?] {
        var count = 0
        return marks.map { mark in
            guard mark.kind == .step else { return nil }
            count += 1
            return count
        }
    }

    /// Moves a mark by `delta` image pixels; its bounds stay inside the image and its size does not change.
    public static func translate(_ mark: AnnotationMark, by delta: CGVector, imageSize: CGSize) -> AnnotationMark {
        let rect = mark.rect
        let x = min(max(0, rect.minX + delta.dx), max(0, imageSize.width - rect.width))
        let y = min(max(0, rect.minY + delta.dy), max(0, imageSize.height - rect.height))
        let dx = x - rect.minX, dy = y - rect.minY
        var moved = mark
        moved.rect.origin = CGPoint(x: x, y: y)
        moved.points = mark.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return moved
    }

    public static func handles(for kind: AnnotationKind) -> [AnnotationHandle] {
        switch kind {
        case .rectangle, .highlighter, .pen, .redaction: [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        case .arrow: [.tail, .tip]
        case .text, .step: []
        }
    }

    /// Where `handle` sits on `mark` (image pixels).
    public static func handlePoint(_ handle: AnnotationHandle, of mark: AnnotationMark) -> CGPoint {
        let r = mark.rect
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .tail: return mark.anchor
        case .tip: return mark.points.last ?? r.origin
        }
    }

    /// Drags `handle` of `mark` to `point` (image pixels, clamped to the image). Kinds without that handle are unchanged.
    public static func resize(_ mark: AnnotationMark, handle: AnnotationHandle, to point: CGPoint,
                              imageSize: CGSize) -> AnnotationMark {
        guard handles(for: mark.kind).contains(handle) else { return mark }
        let p = clamp(point, imageSize)
        if mark.kind == .arrow, mark.points.count == 2 {
            let ends = handle == .tail ? [p, mark.points[1]] : [mark.points[0], p]
            return .arrow(tail: ends[0], tip: ends[1], style: mark.style)
        }
        let old = mark.rect
        var low = CGPoint(x: old.minX, y: old.minY), high = CGPoint(x: old.maxX, y: old.maxY)
        if ([.topLeft, .left, .bottomLeft] as [AnnotationHandle]).contains(handle) { low.x = p.x }
        if ([.topRight, .right, .bottomRight] as [AnnotationHandle]).contains(handle) { high.x = p.x }
        if ([.topLeft, .top, .topRight] as [AnnotationHandle]).contains(handle) { low.y = p.y }
        if ([.bottomLeft, .bottom, .bottomRight] as [AnnotationHandle]).contains(handle) { high.y = p.y }
        let new = CGRect(x: min(low.x, high.x), y: min(low.y, high.y), width: abs(high.x - low.x), height: abs(high.y - low.y))
        var resized = mark
        resized.rect = new
        guard mark.kind != .rectangle, mark.kind != .redaction else { return resized }
        // Samples keep their place within the box; a box flipped by the drag mirrors them, and a zero extent keeps its axis.
        func map(_ value: CGFloat, _ oldLow: CGFloat, _ oldSize: CGFloat, _ newLow: CGFloat, _ newHigh: CGFloat) -> CGFloat {
            guard oldSize > 0 else { return value }
            return newLow + (value - oldLow) / oldSize * (newHigh - newLow)
        }
        resized.points = mark.points.map {
            CGPoint(x: map($0.x, old.minX, old.width, low.x, high.x), y: map($0.y, old.minY, old.height, low.y, high.y))
        }
        resized.rect = AnnotationMark.bounds(resized.points)
        return resized
    }

    private static func clamp(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }
}
