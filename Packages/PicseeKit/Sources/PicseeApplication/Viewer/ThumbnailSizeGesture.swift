import Foundation

/// Like canvas magnification, positive values enlarge and negative values shrink.
/// Keep fractional points during the gesture; the shared preference store owns rounding.
public enum ThumbnailSizeGesture {
    public static func size(from size: Double, magnification: Double) -> Double {
        let start = size.isFinite ? min(280, max(140, size)) : 220
        guard magnification.isFinite else { return start }
        return min(280, max(140, start * exp(magnification)))
    }
}
