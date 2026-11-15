import CoreGraphics

/// Where the Capture Bar sits (#685, grilling 2.2): top centre, 32 px below the menu bar, until the user drags it;
/// after that the last origin per display arrangement, clamped into a visible frame on restore.
public enum CaptureBarPlacement {
    /// Identifies a display arrangement by its screen frames, independent of their order.
    public static func arrangementKey(_ screenFrames: [CGRect]) -> String {
        screenFrames
            .sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
            .map { [$0.minX, $0.minY, $0.width, $0.height].map { String(Int($0.rounded())) }.joined(separator: ",") }
            .joined(separator: ";")
    }

    public static func defaultOrigin(barSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.midX - barSize.width / 2, y: visibleFrame.maxY - 32 - barSize.height)
    }

    /// Moves the bar fully into the visible frame it overlaps most, or into the first one when it overlaps none.
    public static func clamp(_ origin: CGPoint, barSize: CGSize, visibleFrames: [CGRect]) -> CGPoint {
        let bar = CGRect(origin: origin, size: barSize)
        func overlap(_ frame: CGRect) -> CGFloat {
            let shared = frame.intersection(bar)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let first = visibleFrames.first else { return origin }
        let target = visibleFrames.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? first
        func fit(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(value, max(low, high))) }
        return CGPoint(x: fit(origin.x, target.minX, target.maxX - barSize.width),
                       y: fit(origin.y, target.minY, target.maxY - barSize.height))
    }

    /// The saved origin clamped, or the default on the pointer's display.
    public static func origin(saved: CGPoint?, barSize: CGSize, visibleFrames: [CGRect],
                              pointerVisibleFrame: CGRect) -> CGPoint {
        guard let saved else { return defaultOrigin(barSize: barSize, visibleFrame: pointerVisibleFrame) }
        return clamp(saved, barSize: barSize, visibleFrames: visibleFrames)
    }
}

/// The bar's remembered origin per display arrangement and whether it is collapsed to the menu bar.
public protocol CaptureBarLayoutPort: Sendable {
    func origin(forArrangement key: String) async -> CGPoint?
    func setOrigin(_ origin: CGPoint, forArrangement key: String) async
    func isCollapsed() async -> Bool
    func setCollapsed(_ collapsed: Bool) async
}
