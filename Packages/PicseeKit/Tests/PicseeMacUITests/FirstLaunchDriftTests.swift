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

// MARK: - WI-2: the Home view runs and pauses the drift

@MainActor final class I316Clock { var now: CFTimeInterval = 1000 }
/// Reader state the view's closures hold strongly; the Home may outlive its test fixture.
@MainActor final class I316Inputs { var visible = true; var frontmost = true }

/// A Home inside a real (never ordered-in) window; the drift inputs are injected before it enters the window.
@MainActor final class I316Home {
    let window: NSWindow
    let container: NSView
    let view: FirstLaunchView
    let clock: I316Clock
    let inputs = I316Inputs()
    var visible: Bool { get { inputs.visible } set { inputs.visible = newValue } }
    var frontmost: Bool { get { inputs.frontmost } set { inputs.frontmost = newValue } }
    init(visible: Bool = true, frontmost: Bool = true, reduceMotion: Bool = false,
         size: NSSize = NSSize(width: 900, height: 600), clock: I316Clock = I316Clock()) {
        _ = NSApplication.shared
        self.clock = clock
        inputs.visible = visible
        inputs.frontmost = frontmost
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(origin: .zero, size: size))
        view = FirstLaunchView(frame: container.bounds, openButton: ViewerStateButton(frame: .zero), sampleURLs: [:])
        view.reduceMotionOverride = reduceMotion
        view.reduceTransparencyOverride = false
        view.driftClock = { [clock] in clock.now }
        view.windowVisible = { [inputs] _ in inputs.visible }
        view.appFrontmost = { [inputs] in inputs.frontmost }
        container.addSubview(view)
        window.contentView = container
        view.layoutSubtreeIfNeeded()
    }
    func close() { window.close() }
    var tiles: CALayer? { wallLayer("first-launch.wall.tiles", in: view) }
    var drift: CABasicAnimation? { tiles?.animation(forKey: "first-launch.wall.drift") as? CABasicAnimation }
    var base: CGPoint {
        let box = FirstLaunchLayout.wall(in: NSSize(width: view.bounds.width, height: max(0, view.bounds.height - 38))).box
        return CGPoint(x: box.midX, y: box.midY)
    }
    /// Model offset above the layout's resting place.
    var frozenOffset: CGFloat { (tiles?.position.y ?? .nan) - base.y }
    /// Where in the ping-pong cycle the attached animation is now, in seconds of drift, mod 2P.
    var phase: CFTimeInterval? {
        drift.map { ($0.timeOffset + clock.now - $0.beginTime).truncatingRemainder(dividingBy: 2 * FirstLaunchDrift.period) }
    }
}

private func i316Mod(_ t: CFTimeInterval) -> CFTimeInterval { t.truncatingRemainder(dividingBy: 2 * FirstLaunchDrift.period) }

@Test @MainActor func i316DriftRunsOnlyWhenAllInputsHold() throws {
    let (period, range) = try i316Pinned()
    for visible in [false, true] {
        for frontmost in [false, true] {
            for reduceMotion in [false, true] {
                let context = "visible \(visible) frontmost \(frontmost) reduceMotion \(reduceMotion)"
                let home = I316Home(visible: visible, frontmost: frontmost, reduceMotion: reduceMotion)
                defer { home.close() }
                let tiles = try #require(home.tiles)
                #expect(tiles.position.x == home.base.x && tiles.position.y == home.base.y, "\(context): model moved")
                guard visible && frontmost && !reduceMotion else {
                    #expect(tiles.animationKeys() == nil, "\(context): \(tiles.animationKeys() ?? [])")
                    continue
                }
                #expect(tiles.animationKeys() == ["first-launch.wall.drift"], "\(context): \(tiles.animationKeys() ?? [])")
                let drift = try #require(home.drift, "\(context): no drift")
                #expect(drift.keyPath == "position.y", "drift must be vertical in the unrotated wall, not along the tilt")
                #expect(drift.isAdditive)
                #expect((drift.fromValue as? NSNumber)?.doubleValue == 0)
                #expect((drift.toValue as? NSNumber)?.doubleValue == Double(range), "up by page 21's range")
                #expect(drift.duration == period)
                #expect(drift.autoreverses && drift.repeatCount == .infinity)
                #expect(drift.timingFunction == CAMediaTimingFunction(name: .linear))
                #expect(drift.beginTime == home.clock.now && drift.timeOffset == 0)
                let tileKeys = home.tiles?.sublayers?.flatMap { $0.animationKeys() ?? [] } ?? []
                #expect(tileKeys.isEmpty, "per-tile animations \(tileKeys)")
            }
        }
    }
}

@Test @MainActor func i316HideFreezesOffsetAndUnhideResumesSamePhase() throws {
    let (period, range) = try i316Pinned()
    let home = I316Home()
    defer { home.close() }
    home.clock.now += 10
    home.view.isHidden = true
    #expect(home.drift == nil)
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 10)) && home.frozenOffset > 0,
            "frozen offset \(home.frozenOffset)")
    #expect(home.tiles?.animationKeys() == nil, "implicit animation \(home.tiles?.animationKeys() ?? [])")
    home.clock.now += 40
    home.view.isHidden = false
    let resumed = try #require(home.drift)
    #expect(resumed.beginTime == home.clock.now && i316Close(CGFloat(resumed.timeOffset), 10), "hidden time counted")
    #expect(home.tiles?.position.y == home.base.y, "model keeps the frozen offset while the additive drift runs")
    #expect(home.tiles?.animationKeys() == ["first-launch.wall.drift"])
    home.clock.now += 1.5 * period - 10
    home.view.isHidden = true
    #expect(i316Close(home.frozenOffset, range / 2, 1e-6), "downward leg \(home.frozenOffset)")
    home.view.isHidden = false
    let second = try #require(home.drift)
    #expect(i316Close(CGFloat(i316Mod(second.timeOffset)), CGFloat(1.5 * period)), "timeOffset \(second.timeOffset) lost the leg")
}

@Test @MainActor func i316HiddenAncestorPausesAndResumes() throws {
    let home = I316Home()
    defer { home.close() }
    home.clock.now += 12
    home.container.isHidden = true
    #expect(home.drift == nil)
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 12)))
    home.clock.now += 5
    home.container.isHidden = false
    #expect(home.drift.map { i316Close(CGFloat($0.timeOffset), 12) } == true)
}

@Test @MainActor func i316ElapsedDriftIsConservedAcrossToggles() throws {
    let home = I316Home()
    defer { home.close() }
    var generator = SplitMix64(seed: 0x3160)
    var running = true, sum: CFTimeInterval = 0
    for step in 0..<200 {
        let dt = Double.random(in: 0.5...200, using: &generator)
        home.clock.now += dt
        if running { sum += dt }
        let before = home.drift.map { ($0.beginTime, $0.timeOffset) }
        let hide = Bool.random(using: &generator)
        home.view.isHidden = hide
        running = !hide
        if running {
            let drift = try #require(home.drift, "step \(step): not running")
            if let before {
                #expect(before.0 == drift.beginTime && before.1 == drift.timeOffset, "step \(step): restarted while running")
            }
            #expect(abs((home.phase ?? .nan) - i316Mod(sum)) < 1e-6, "step \(step): phase \(home.phase ?? .nan) vs \(i316Mod(sum))")
            #expect(home.tiles?.position.y == home.base.y)
        } else {
            #expect(home.drift == nil, "step \(step): still running")
            #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: sum), 1e-6),
                    "step \(step): frozen \(home.frozenOffset) vs \(FirstLaunchDrift.offset(elapsed: sum))")
        }
    }
}

@Test @MainActor func i316RelayoutKeepsFrozenOffsetAndRunningAnimation() throws {
    let home = I316Home(size: NSSize(width: 900, height: 600))
    defer { home.close() }
    func resize(_ size: NSSize) {
        home.window.setContentSize(size)
        home.container.frame = NSRect(origin: .zero, size: size)
        home.view.frame = home.container.bounds
        home.view.layoutSubtreeIfNeeded()
    }
    home.clock.now += 20
    let running = try #require(home.drift)
    resize(NSSize(width: 1000, height: 700))
    let after = try #require(home.drift)
    #expect(after.beginTime == running.beginTime && after.timeOffset == running.timeOffset, "relayout restarted the drift")
    #expect(home.tiles?.position.x == home.base.x && home.tiles?.position.y == home.base.y)
    home.view.isHidden = true
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 20)))
    resize(NSSize(width: 1200, height: 800))
    #expect(home.tiles?.position.x == home.base.x)
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 20)), "relayout snapped \(home.frozenOffset)")
}
