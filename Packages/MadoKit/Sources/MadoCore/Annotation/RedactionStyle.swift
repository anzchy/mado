/// How a redaction hides the pixels inside its rectangle (#693, grilling decision 5.3).
public enum RedactionStyle: Hashable, Sendable {
    /// Square cells `strength` image pixels wide, each filled with the mean colour of its source pixels.
    case mosaic(strength: Int)
    /// Opaque black.
    case solid
}
