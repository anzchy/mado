import AppKit
import Testing
import PicseeApplication
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

// MARK: - WI-3: live inputs, Reduce Motion, leaving the Home, drag fade

private func i316Post(_ name: Notification.Name, _ object: Any?) { NotificationCenter.default.post(name: name, object: object) }
private func i316PostAccessibilityChange() {
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
}

@Test @MainActor func i316AppAndWindowNotificationsPauseAndResume() throws {
    struct Case { let pause: Notification.Name; let resume: Notification.Name; let app: Bool; let flipsFrontmost: Bool }
    let cases = [
        Case(pause: NSApplication.didResignActiveNotification, resume: NSApplication.didBecomeActiveNotification, app: true, flipsFrontmost: true),
        Case(pause: NSApplication.didHideNotification, resume: NSApplication.didUnhideNotification, app: true, flipsFrontmost: false),
        Case(pause: NSWindow.didMiniaturizeNotification, resume: NSWindow.didDeminiaturizeNotification, app: false, flipsFrontmost: false),
        Case(pause: NSWindow.didChangeOcclusionStateNotification, resume: NSWindow.didChangeOcclusionStateNotification, app: false, flipsFrontmost: false)
    ]
    for item in cases {
        let home = I316Home()
        defer { home.close() }
        let object: Any = item.app ? NSApplication.shared : home.window
        home.clock.now += 7
        if item.flipsFrontmost { home.frontmost = false } else { home.visible = false }
        i316Post(item.pause, object)
        #expect(home.drift == nil, "\(item.pause.rawValue) did not pause")
        #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 7)), "\(item.pause.rawValue) froze at \(home.frozenOffset)")
        home.clock.now += 30
        if item.flipsFrontmost { home.frontmost = true } else { home.visible = true }
        i316Post(item.resume, object)
        let resumed = try #require(home.drift, "\(item.resume.rawValue) did not resume")
        #expect(i316Close(CGFloat(resumed.timeOffset), 7) && resumed.beginTime == home.clock.now, "\(item.resume.rawValue) phase")
    }
}

@Test @MainActor func i316NotificationsReReadEveryInput() throws {
    let home = I316Home()
    defer { home.close() }
    let start = try #require(home.drift)
    home.clock.now += 10
    i316Post(NSApplication.didResignActiveNotification, NSApplication.shared)
    #expect(home.drift.map { $0.beginTime == start.beginTime && $0.timeOffset == start.timeOffset } == true,
            "the notification name is not the state: the app reader still says frontmost")
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
                         backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    home.visible = false
    i316Post(NSWindow.didMiniaturizeNotification, other)
    #expect(home.drift.map { $0.beginTime == start.beginTime } == true, "another window's notification paused the drift")
    home.visible = true
    home.frontmost = false
    i316Post(NSWindow.didChangeOcclusionStateNotification, home.window)
    #expect(home.drift == nil, "a window notification must re-read the app input too")
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 10)))
}

@Test @MainActor func i316ReduceMotionLiveStopsAndResumes() throws {
    let home = I316Home()
    defer { home.close() }
    home.clock.now += 20
    home.view.reduceMotionOverride = true
    i316PostAccessibilityChange()
    #expect(home.drift == nil, "Reduce Motion on did not stop the drift at once")
    #expect(home.tiles?.animationKeys() == nil)
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 20)), "Reduce Motion freezes in place, no snap")
    home.clock.now += 30
    home.view.reduceMotionOverride = false
    i316PostAccessibilityChange()
    let resumed = try #require(home.drift, "Reduce Motion off did not resume")
    #expect(i316Close(CGFloat(resumed.timeOffset), 20), "Reduce Motion time counted: \(resumed.timeOffset)")
    home.frontmost = false
    home.view.reduceMotionOverride = true
    i316PostAccessibilityChange()
    home.view.reduceMotionOverride = false
    i316PostAccessibilityChange()
    #expect(home.drift == nil, "resumed while picsee is in the background")
}

@Test @MainActor func i316LeavingHomeReleasesDriftForEveryExit() throws {
    for exit in [ViewerImageStatus.loading("a.jpg"), .readingFolder, .showing] {
        let scene = StatesScene()
        defer { scene.window.close() }
        scene.state.display(.empty)
        let home = try launch(in: scene)
        let inputs = I316Inputs()
        home.windowVisible = { [inputs] _ in inputs.visible }
        home.appFrontmost = { [inputs] in inputs.frontmost }
        home.reduceMotionOverride = false
        i316Post(NSApplication.didBecomeActiveNotification, NSApplication.shared)
        let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
        #expect(tiles.animation(forKey: "first-launch.wall.drift") != nil, "\(exit): Home did not start drifting")
        scene.state.display(exit)
        #expect(home.window == nil, "\(exit): Home still in the window")
        #expect(tiles.animationKeys() == nil, "\(exit): animation kept after leaving: \(tiles.animationKeys() ?? [])")
        i316Post(NSApplication.didBecomeActiveNotification, NSApplication.shared)
        i316Post(NSWindow.didChangeOcclusionStateNotification, scene.window)
        i316Post(NSWindow.didDeminiaturizeNotification, scene.window)
        i316PostAccessibilityChange()
        #expect(tiles.animationKeys() == nil, "\(exit): a later notification restarted the drift")
    }
}

/// The drift (animation, readers, observers) must not keep a Home alive once it leaves its window. The host path
/// is not used: on main the state host already keeps its last Home object alive after leaving (reported in #316).
@Test @MainActor func i316OldHomeIsReleasedAfterLeaving() throws {
    weak var released: FirstLaunchView?
    var window: NSWindow?
    autoreleasepool {
        let home = I316Home()
        i316Post(NSApplication.didBecomeActiveNotification, NSApplication.shared)
        home.clock.now += 3
        #expect(home.drift != nil, "the Home never drifted")
        released = home.view
        home.view.removeFromSuperview()
        i316Post(NSApplication.didBecomeActiveNotification, NSApplication.shared)
        window = home.window
    }
    window?.close()
    #expect(released == nil, "the drift keeps the old Home alive")
}

@Test @MainActor func i316DragFadeAndDriftCoexist() throws {
    let home = I316Home()
    defer { home.close() }
    home.clock.now += 5
    let start = try #require(home.drift)
    home.view.setDragActive(true)
    #expect(!wallOpacityAnimations(home.view).isEmpty, "drag fade missing while drifting")
    #expect(home.drift.map { $0.beginTime == start.beginTime && $0.timeOffset == start.timeOffset } == true, "drag restarted the drift")
    home.view.setDragActive(false)
    #expect(home.drift.map { $0.beginTime == start.beginTime && $0.timeOffset == start.timeOffset } == true, "drag end restarted the drift")
    home.view.setDragActive(true)
    home.view.reduceMotionOverride = true
    i316PostAccessibilityChange()
    #expect(wallOpacityAnimations(home.view).isEmpty && home.drift == nil, "Reduce Motion during a drag keeps motion")
}

// MARK: - Review fix round: the window-visibility rule and window moves

@Test func i316WindowVisibilityTruthTable() {
    for onScreen in [false, true] {
        for miniaturized in [false, true] {
            for appHidden in [false, true] {
                let expected = onScreen && !miniaturized && !appHidden
                #expect(FirstLaunchDrift.windowIsVisible(onScreen: onScreen, miniaturized: miniaturized, appHidden: appHidden) == expected,
                        "onScreen \(onScreen) miniaturized \(miniaturized) appHidden \(appHidden)")
            }
        }
    }
}

@Test @MainActor func i316MovingToAnotherWindowIgnoresTheOldWindow() throws {
    let home = I316Home()
    defer { home.close() }
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: .borderless,
                         backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    other.contentView = host
    host.addSubview(home.view)
    let start = try #require(home.drift, "not drifting in the new window")
    home.visible = false
    NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: home.window)
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: home.window)
    #expect(home.drift.map { $0.beginTime == start.beginTime } == true, "the old window still drives the drift")
    NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: other)
    #expect(home.drift == nil, "the new window's notification did not pause the drift")
}

// MARK: - Fix round 1: window close, frame rate, observer removal

/// ⌘W keeps a reusable window (`isReleasedWhenClosed = false`) and the Home inside it. Closing pauses the drift at
/// once, even before any reader reports the window gone; showing it again resumes only if every input holds.
@Test @MainActor func i316ClosingTheWindowPausesAndReopeningResumesOnlyWhenAllowed() throws {
    let home = I316Home()
    defer { home.close() }
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
                         backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    let start = try #require(home.drift, "the Home never drifted")
    home.clock.now += 9
    i316Post(NSWindow.willCloseNotification, other)
    #expect(home.drift.map { $0.beginTime == start.beginTime } == true, "another window's close paused the drift")
    i316Post(NSWindow.willCloseNotification, home.window)
    #expect(home.drift == nil, "closing the Home's window did not pause the drift")
    #expect(i316Close(home.frozenOffset, FirstLaunchDrift.offset(elapsed: 9)), "close froze at \(home.frozenOffset)")
    home.clock.now += 40
    home.frontmost = false
    i316Post(NSWindow.didChangeOcclusionStateNotification, home.window)
    #expect(home.drift == nil, "shown again in the background: resumed")
    home.frontmost = true
    i316Post(NSApplication.didBecomeActiveNotification, NSApplication.shared)
    let resumed = try #require(home.drift, "shown again while frontmost: did not resume")
    #expect(i316Close(CGFloat(resumed.timeOffset), 9) && resumed.beginTime == home.clock.now,
            "closed time counted: \(resumed.timeOffset)")
}

/// About 6 pt/s needs no display-rate recomposite of the whole wall: a low preferred rate whose per-frame step
/// stays at or under half a pixel at @2x (0.25 pt), capped well below 60 Hz. Claims no CPU or GPU figure.
@Test @MainActor func i316DriftRequestsALowFrameRate() throws {
    let (period, range) = try i316Pinned()
    let rate = FirstLaunchDrift.frameRate
    let preferred = try #require(rate.preferred, "no preferred rate")
    #expect(rate.minimum > 0 && rate.minimum <= preferred && preferred <= rate.maximum,
            "range \(rate.minimum)…\(preferred)…\(rate.maximum)")
    #expect(rate.maximum <= 30, "maximum \(rate.maximum) Hz recomposites the wall near the display rate")
    let step = range / CGFloat(period) / CGFloat(preferred)
    #expect(step <= 0.25, "\(step) pt per frame at the preferred rate")
    let home = I316Home()
    defer { home.close() }
    let drift = try #require(home.drift)
    #expect(drift.preferredFrameRateRange.minimum == rate.minimum && drift.preferredFrameRateRange.maximum == rate.maximum
            && drift.preferredFrameRateRange.preferred == rate.preferred, "the drift does not carry the low frame rate")
    home.clock.now += 4
    home.visible = false
    i316Post(NSWindow.didChangeOcclusionStateNotification, home.window)
    home.visible = true
    i316Post(NSWindow.didChangeOcclusionStateNotification, home.window)
    let resumed = try #require(home.drift)
    #expect(resumed.preferredFrameRateRange.preferred == rate.preferred, "a resumed drift lost the frame rate")
}

@MainActor final class I316ReadCount { var frontmostReads = 0 }

/// Every drift trigger reads the app input once, so the read count shows how many registrations a notification
/// reaches: none after leaving the window, exactly one after coming back (characterization).
@Test @MainActor func i316LeavingAndReturningLeavesOneRegistrationPerTrigger() throws {
    let home = I316Home()
    defer { home.close() }
    let count = I316ReadCount()
    home.view.appFrontmost = { [count] in count.frontmostReads += 1; return true }
    home.view.removeFromSuperview()
    count.frontmostReads = 0
    i316Post(NSApplication.didBecomeActiveNotification, NSApplication.shared)
    i316Post(NSWindow.didChangeOcclusionStateNotification, home.window)
    i316Post(NSWindow.willCloseNotification, home.window)
    #expect(count.frontmostReads == 0, "a trigger still reached the Home after it left: \(count.frontmostReads)")
    home.container.addSubview(home.view)
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                 NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
        count.frontmostReads = 0
        i316Post(name, NSApplication.shared)
        #expect(count.frontmostReads == 1, "\(name.rawValue) reached \(count.frontmostReads) registrations")
    }
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
        count.frontmostReads = 0
        i316Post(name, home.window)
        #expect(count.frontmostReads == 1, "\(name.rawValue) reached \(count.frontmostReads) registrations")
    }
}

/// Leaving the Home through ⌘O (device smoke run=20261101-212141-i316s): the App puts the Reading State on the reading
/// surface before the scan starts, while the Session still reads `.empty`. The Session's observation refresh in that
/// gap rebuilt the Home, whose drift ran for about 8 ms until the scan began and hid it again.
@Test @MainActor func i316LeavingTheHomeForAFolderReadNeverRebuildsTheHome() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    #expect(scene.state.subviews.contains { $0 is FirstLaunchView }, "the scene starts on the Home")
    scene.session.enterFolderGrid(items: [], sourceVersion: .init(0))
    scene.state.surface = .gridReading
    scene.state.display(.readingFolder)
    #expect(scene.session.imageStatus == .empty, "the gap before the scan starts")
    scene.state.refresh()
    #expect(!scene.state.subviews.contains { $0 is FirstLaunchView }, "the Session's .empty rebuilt the Home on the reading surface")
    #expect(scene.state.textLines.first == "Reading Folder…")
    scene.state.surface = .viewer
    #expect(scene.state.subviews.contains { $0 is FirstLaunchView }, "back on the viewer surface the Home returns")
}
