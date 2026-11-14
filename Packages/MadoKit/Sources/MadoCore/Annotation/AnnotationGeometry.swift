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

    /// The topmost mark whose rectangle, grown by half its stroke, contains `point` (image pixels).
    public static func hitTest(_ point: CGPoint, marks: [AnnotationMark]) -> Int? {
        marks.indices.last { index in
            let half = marks[index].style.lineWidth / 2
            return marks[index].rect.insetBy(dx: -half, dy: -half).contains(point)
        }
    }

    /// Moves `rect` by whole image pixels, kept inside the image without changing its size.
    public static func nudge(_ rect: CGRect, dx: Int, dy: Int, imageSize: CGSize) -> CGRect {
        var moved = rect
        moved.origin.x = min(max(0, rect.minX + CGFloat(dx)), max(0, imageSize.width - rect.width))
        moved.origin.y = min(max(0, rect.minY + CGFloat(dy)), max(0, imageSize.height - rect.height))
        return moved
    }
}
