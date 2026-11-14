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
}

/// One mark in Annotate Mode. `rect` is in displayed (upright) image pixels, origin at the top left.
public struct AnnotationMark: Hashable, Sendable {
    public var rect: CGRect
    public var style: AnnotationStyle
    public init(rect: CGRect, style: AnnotationStyle = .default) {
        self.rect = rect; self.style = style
    }
}

/// Why an Annotated Copy was not written. The original is never changed in any of these cases.
public enum AnnotatedCopyError: Error, Equatable, Sendable {
    case permissionDenied, diskFull, folderMissing, sourceMissing, sourceIsTarget
    case encodeFailed, nameExhausted, accessLost, writeFailed
}
