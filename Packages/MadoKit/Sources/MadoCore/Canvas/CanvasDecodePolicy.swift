import Foundation

/// Initial small preview, viewport detail, then source resolution beyond fit.
public enum CanvasDecodePolicy {
    public static let previewMaximumPixelSize = 512
    public static func maximumPixelSize(source: CGSize, viewport: CGSize, zoom: Double) -> Int {
        precondition(source.width > 0 && source.height > 0 && viewport.width > 0 && viewport.height > 0)
        let sourceEdge = max(source.width, source.height)
        let fit = min(1, min(viewport.width / source.width, viewport.height / source.height))
        let maximum = zoom > fit ? sourceEdge : min(sourceEdge, max(viewport.width, viewport.height))
        return max(1, Int(ceil(maximum)))
    }
}

/// Tracks delivered pixels, independently of the requested edge and preview mode.
public struct CanvasDecodeProgress: Sendable {
    public private(set) var completedMaximum = 0
    public private(set) var previewCompleted = false
    private var sourceMaximum = Int.max
    private var viewportCompleted = false
    private var revisionRetryUsed = false
    public init() { }
    public func nextMaximum(desired: Int) -> Int? {
        guard desired > 0 else { return nil }
        if !previewCompleted { return min(CanvasDecodePolicy.previewMaximumPixelSize, desired) }
        let target = min(desired, sourceMaximum)
        return !viewportCompleted || target > completedMaximum ? target : nil
    }
    /// Retry only a still-bound request, once until a successful install breaks the sequence.
    public mutating func restartForRevision(request: PresentationToken, current: PresentationToken) -> Bool {
        guard request == current, !revisionRetryUsed else { return false }
        self = CanvasDecodeProgress()
        revisionRetryUsed = true
        return true
    }
    public mutating func completed(_ image: DecodedImage, isPreview: Bool) {
        revisionRetryUsed = false
        completedMaximum = max(image.image.width, image.image.height)
        sourceMaximum = Int(max(image.sourcePixelSize.width, image.sourcePixelSize.height))
        previewCompleted = true
        viewportCompleted = viewportCompleted || !isPreview
    }
}
