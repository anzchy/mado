import AppKit

/// Image Wall drift from pinned page 21: `animation: home-wall-drift 60s linear infinite alternate`, keyframes
/// `translate: 0 0` → `0 -362px`. CSS `translate` sits outside the tilt, so the drift is vertical on screen;
/// AppKit's upward Y makes it +362. The drift runs only while the window is visible, picsee is frontmost
/// and Reduce Motion is off (#316, 「只在窗口可见且在前台时」).
enum FirstLaunchDrift {
    /// One leg (up or down); `alternate` makes a full cycle twice this.
    static let period: CFTimeInterval = 60
    static let range: CGFloat = 362

    static func mayAnimate(visible: Bool, frontmost: Bool, reduceMotion: Bool) -> Bool {
        visible && frontmost && !reduceMotion
    }

    /// Ping-pong offset after `elapsed` seconds of drift: up for one period, back down for the next.
    static func offset(elapsed: CFTimeInterval) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: 2 * period)
        let leg = phase <= period ? phase : 2 * period - phase
        return range * CGFloat(leg / period)
    }

    /// Not minimised, not hidden with the app, and at least partly on screen (not fully covered).
    @MainActor static func windowIsVisible(_ window: NSWindow) -> Bool {
        // Read every condition up front: a window that is never on screen must still exercise the whole rule.
        let conditions = [window.occlusionState.contains(.visible), !window.isMiniaturized, !NSApplication.shared.isHidden]
        return !conditions.contains(false)
    }

    @MainActor static func appIsFrontmost() -> Bool { NSApplication.shared.isActive }
}
