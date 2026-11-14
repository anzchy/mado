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
    /// TODO-design (OQ-1): the prototype's fixed red and stroke width until page 39 pins them; may not ship as is.
    public static let `default` = AnnotationStyle(red: 1, green: 59.0 / 255, blue: 48.0 / 255, lineWidth: 4)
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
