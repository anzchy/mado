import AppKit

/// Image Wall drift from pinned page 21: `animation: home-wall-drift 60s linear infinite alternate`, keyframes
/// `translate: 0 0` → `0 -362px`. CSS `translate` sits outside the tilt, so the drift is vertical on screen;
/// AppKit's upward Y makes it +362. The drift runs only while the window is visible, picsee is frontmost
/// and Reduce Motion is off (#316, 「只在窗口可见且在前台时」).
enum FirstLaunchDrift {
    /// One leg (up or down); `alternate` makes a full cycle twice this.
    static let period: CFTimeInterval = 60
    static let range: CGFloat = 362
    /// The wall moves range/period ≈ 6 pt/s, yet left alone Core Animation recomposites 60 shadowed tiles at the
    /// display rate (up to 120 Hz) for steps of ~0.05 pt. At 25 Hz a frame moves ~0.24 pt, under half a pixel at
    /// @2x, which still reads as continuous; 15 Hz (~0.4 pt) is the floor and 30 Hz the cap.
    static let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 25)

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
    static func windowIsVisible(onScreen: Bool, miniaturized: Bool, appHidden: Bool) -> Bool {
        onScreen && !miniaturized && !appHidden
    }

    @MainActor static func windowIsVisible(_ window: NSWindow) -> Bool {
        windowIsVisible(onScreen: window.occlusionState.contains(.visible), miniaturized: window.isMiniaturized,
                        appHidden: NSApplication.shared.isHidden)
    }

    @MainActor static func appIsFrontmost() -> Bool { NSApplication.shared.isActive }
}
