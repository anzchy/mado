/// How a redaction hides the pixels inside its rectangle (#693, grilling decision 5.3).
public enum RedactionStyle: Hashable, Sendable {
    /// Square cells `strength` image pixels wide, each filled with the mean colour of its source pixels.
    case mosaic(strength: Int)
    /// Opaque black.
    case solid

    /// Decision 5.3, 「下限足以糊掉整行字」: the weakest mosaic must make a line of body text unreadable.
    /// docs/validation/P7-693-mosaic-minimum.md measured 8 as the smallest cell size from which Apple Vision reads
    /// no character of any sample line (13/15/17 pt, @1x and @2x, Chinese and English); the minimum doubles it.
    public static let minimumMosaicStrength = 16

    /// The style as it is rendered: a mosaic weaker than the minimum is raised to the minimum.
    public var enforced: RedactionStyle {
        switch self {
        case .mosaic(let strength): .mosaic(strength: max(strength, Self.minimumMosaicStrength))
        case .solid: .solid
        }
    }
}
