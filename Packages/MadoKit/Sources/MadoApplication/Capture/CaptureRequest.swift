import Foundation

public struct CaptureRequest: Sendable {
    public enum Target: Sendable {
        case region(rect: CGRect, displayID: UInt32, displayFrame: CGRect, scale: CGFloat)
        case window(windowID: UInt32)
        case fullScreen(displayID: UInt32)
    }

    public let target: Target
    public let excludedWindowIDs: Set<UInt32>

    public init(target: Target, barWindowIDs: Set<UInt32>, overlayWindowIDs: Set<UInt32>) {
        self.target = target
        self.excludedWindowIDs = barWindowIDs.union(overlayWindowIDs)
    }

    /// ScreenCaptureKit and CGImage crop coordinates start at the display's top-left.
    public var regionPixelRect: CGRect? {
        guard case let .region(rect, _, displayFrame, scale) = target else { return nil }
        let clipped = rect.standardized.intersection(displayFrame)
        guard !clipped.isNull, !clipped.isEmpty, scale > 0 else { return nil }
        let minX = floor((clipped.minX - displayFrame.minX) * scale)
        let maxX = ceil((clipped.maxX - displayFrame.minX) * scale)
        let minY = floor((displayFrame.maxY - clipped.maxY) * scale)
        let maxY = ceil((displayFrame.maxY - clipped.minY) * scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
