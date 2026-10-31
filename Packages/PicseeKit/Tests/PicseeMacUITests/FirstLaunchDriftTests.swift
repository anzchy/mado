import AppKit
import Testing
@testable import PicseeMacUI

/// Page 21 `.wall .tiles { animation: home-wall-drift … }` and its keyframes; CSS Y points down, AppKit's up.
private func i316Pinned() throws -> (period: Double, range: CGFloat) {
    let page = try PinnedDesign.page("first-launch")
    let animation = try page.animation(".wall .tiles")
    let frames = try page.keyframes(animation.name)
    return (animation.duration, CGFloat(-frames.to.y))
}

private func i316Close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-6) -> Bool { abs(a - b) <= tolerance }

@Test func i316MayAnimateTruthTable() {
    for visible in [false, true] {
        for frontmost in [false, true] {
            for reduceMotion in [false, true] {
                let expected = visible && frontmost && !reduceMotion
                #expect(FirstLaunchDrift.mayAnimate(visible: visible, frontmost: frontmost, reduceMotion: reduceMotion) == expected,
                        "visible \(visible) frontmost \(frontmost) reduceMotion \(reduceMotion)")
            }
        }
    }
}

@Test func i316DriftConstantsMatchPinnedPage21() throws {
    let page = try PinnedDesign.page("first-launch")
    let animation = try page.animation(".wall .tiles")
    #expect(animation.name == "home-wall-drift")
    #expect(animation.timing == "linear" && animation.iterations == "infinite" && animation.direction == "alternate")
    let frames = try page.keyframes(animation.name)
    #expect(frames.from.x == 0 && frames.from.y == 0 && frames.to.x == 0, "drift is vertical from rest")
    #expect(frames.to.y < 0, "page 21 drifts up (negative CSS Y)")
    #expect(try page.reducedMotionAnimation(".wall .tiles") == "none")
    #expect(FirstLaunchDrift.period == animation.duration)
    #expect(FirstLaunchDrift.range == CGFloat(-frames.to.y))
}

@Test func i316OffsetPingPongLaws() throws {
    let (period, range) = try i316Pinned()
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: period), range), "offset(P) \(FirstLaunchDrift.offset(elapsed: period))")
    var generator = SplitMix64(seed: 0x316)
    let samples = (0..<500).map { _ in Double.random(in: 0...(10 * period), using: &generator) }
    for (index, t) in samples.enumerated() {
        let value = FirstLaunchDrift.offset(elapsed: t)
        #expect(value >= -1e-9 && value <= range + 1e-9, "offset(\(t)) = \(value) outside 0…\(range)")
        #expect(i316Close(value, FirstLaunchDrift.offset(elapsed: t + 2 * period), 1e-6), "not 2P-periodic at \(t)")
        let mirrored = 2 * period - t.truncatingRemainder(dividingBy: 2 * period)
        #expect(i316Close(value, FirstLaunchDrift.offset(elapsed: mirrored), 1e-6), "not symmetric at \(t)")
        let other = samples[(index + 1) % samples.count]
        let bound = range / CGFloat(period) * CGFloat(abs(t - other)) + 1e-6
        #expect(abs(value - FirstLaunchDrift.offset(elapsed: other)) <= bound, "faster than \(range)/\(period) between \(t) and \(other)")
    }
}

@Test func i316OffsetBoundaries() throws {
    let (period, range) = try i316Pinned()
    #expect(FirstLaunchDrift.offset(elapsed: 0) == 0)
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: period), range))
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: 2 * period), 0))
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: 3 * period), range))
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: 1.5 * period), range / 2), "downward leg at 1.5P")
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: period / 4), range / 4))
    let huge = 1e7
    let expectedHuge = FirstLaunchDrift.offset(elapsed: huge.truncatingRemainder(dividingBy: 2 * period))
    #expect(i316Close(FirstLaunchDrift.offset(elapsed: huge), expectedHuge, 1e-4))
    #expect(FirstLaunchDrift.offset(elapsed: -5) == 0, "negative elapsed clamps to rest")
}

@Test @MainActor func i316DefaultReadersOnRealWindow() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .titled,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    #expect(!FirstLaunchDrift.windowIsVisible(window), "a window never ordered in is not visible")
    #expect(FirstLaunchDrift.appIsFrontmost() == NSApplication.shared.isActive)
}
