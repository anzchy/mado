import CoreGraphics

/// How a mark is drawn. Colour components are sRGB in 0…1; the line width is in image pixels.
public struct AnnotationStyle: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var lineWidth: Double
    public init(red: Double, green: Double, blue: Double, lineWidth: Double) {
        self.red = red; self.green = green; self.blue = blue; self.lineWidth = lineWidth
    }
    /// Page 39 (#690, B7): the fixed paint #dc2626, the same in light and dark. The line width is the one a mark
    /// gets at 1:1; marks drawn on screen use `forScreen(pointsPerImagePixel:)`.
    public static let `default` = AnnotationStyle(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255,
                                                  lineWidth: screenLineWidth)
    /// Page 39: every mark is stroked 3 pt wide on screen.
    public static let screenLineWidth = 3.0
    /// The style for a mark drawn while `pointsPerImagePixel` view points show one image pixel: the stroke is
    /// stored in image pixels, so the flattened copy shows the width that was seen when it was drawn.
    public static func forScreen(pointsPerImagePixel: Double) -> AnnotationStyle {
        var style = Self.default
        style.lineWidth = screenLineWidth / pointsPerImagePixel
        return style
    }
    /// Image pixels per screen point when the mark was drawn: every other size of a mark is a multiple of it.
    public var unit: Double { lineWidth / Self.screenLineWidth }
}

/// The kinds of mark on page 39's strip (#690 rectangle; #692 the rest; #693 redaction).
public enum AnnotationKind: Hashable, Sendable, CaseIterable {
    case rectangle, arrow, text, highlighter, pen, step, redaction
}

/// #692: page 39's sizes in screen points; a mark's size in image pixels is the value times its style's `unit`.
public enum AnnotationMetrics {
    /// The arrow head: two open arms of 14 pt at ±42° from the shaft (page 39's `M479 576 L492 572 L495 586`).
    public static let arrowHeadLength = 14.0
    public static let arrowHeadAngleDegrees = 42.0
    /// The step marker: a 28 pt disc (`r="14"`) with a 15 pt semibold white number.
    public static let stepDiameter = 28.0
    public static let stepFontSize = 15.0
    /// The text mark: 18 pt semibold with a 3 pt white halo under the fill (`paint-order="stroke"`).
    public static let textFontSize = 18.0
    public static let textHalo = 3.0
    /// Brief defaults (page 39 has no value): the highlighter is 14 pt at 35% opacity; the pen is 3 pt, opaque.
    public static let highlighterWidth = 14.0
    public static let highlighterOpacity = 0.35
    public static let penWidth = 3.0

    /// The stroke width a mark is drawn with, in image pixels.
    public static func drawnWidth(_ mark: AnnotationMark) -> Double {
        mark.kind == .highlighter ? highlighterWidth * mark.style.unit : mark.style.lineWidth
    }
}

/// One mark in Annotate Mode, in displayed (upright) image pixels with the origin at the top left. `rect` is the
/// rectangle of a rectangle mark and the bounds of every other kind. `points` are an arrow's tail and tip, the
/// samples of a pen or highlighter stroke, a step marker's centre, or a text mark's top-left origin.
public struct AnnotationMark: Hashable, Sendable {
    public var kind: AnnotationKind
    public var rect: CGRect
    public var points: [CGPoint]
    public var text: String
    public var style: AnnotationStyle
    /// #693: how a redaction hides its `rect`; nil for every other kind.
    public var redaction: RedactionStyle?

    /// A rectangle.
    public init(rect: CGRect, style: AnnotationStyle = .default) {
        self.init(kind: .rectangle, rect: rect, points: [], text: "", style: style)
    }

    public init(kind: AnnotationKind, rect: CGRect, points: [CGPoint], text: String, style: AnnotationStyle,
                redaction: RedactionStyle? = nil) {
        self.kind = kind; self.rect = rect; self.points = points; self.text = text; self.style = style
        self.redaction = redaction
    }

    /// #693: a redaction of `rect` (image pixels).
    public static func redaction(rect: CGRect, style: RedactionStyle) -> AnnotationMark {
        AnnotationMark(kind: .redaction, rect: rect, points: [], text: "", style: .default, redaction: style)
    }

    /// The first point (an arrow's tail, a text mark's origin, a step's centre), or the rect's origin for a mark
    /// without points.
    public var anchor: CGPoint { points.first ?? rect.origin }

    public static func arrow(tail: CGPoint, tip: CGPoint, style: AnnotationStyle = .default) -> AnnotationMark {
        AnnotationMark(kind: .arrow, rect: bounds([tail, tip]), points: [tail, tip], text: "", style: style)
    }

    /// A pen or highlighter stroke through every sample.
    public static func stroke(_ kind: AnnotationKind, points: [CGPoint], style: AnnotationStyle = .default) -> AnnotationMark {
        AnnotationMark(kind: kind, rect: bounds(points), points: points, text: "", style: style)
    }

    public static func step(centre: CGPoint, style: AnnotationStyle = .default) -> AnnotationMark {
        let half = AnnotationMetrics.stepDiameter * style.unit / 2
        return AnnotationMark(kind: .step, rect: CGRect(x: centre.x - half, y: centre.y - half, width: half * 2, height: half * 2),
                              points: [centre], text: "", style: style)
    }

    /// A text mark whose measured line box is `size`, its top-left corner at `origin`.
    public static func text(_ text: String, origin: CGPoint, size: CGSize, style: AnnotationStyle = .default) -> AnnotationMark {
        AnnotationMark(kind: .text, rect: CGRect(origin: origin, size: size), points: [origin], text: text, style: style)
    }

    /// The smallest rectangle holding every point; zero for none.
    public static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var low = first, high = first
        for point in points.dropFirst() {
            low = CGPoint(x: min(low.x, point.x), y: min(low.y, point.y))
            high = CGPoint(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        return CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }
}

/// Why an Annotated Copy was not written. The original is never changed in any of these cases.
public enum AnnotatedCopyError: Error, Equatable, Sendable {
    case permissionDenied, diskFull, folderMissing, sourceMissing, sourceIsTarget
    case encodeFailed, nameExhausted, accessLost, writeFailed
}
