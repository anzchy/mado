import AppKit
import QuartzCore
import Testing
import MadoApplication
@testable import MadoMacUI

@MainActor private func waitingText() -> LostAccessStateText {
    .init(title: "External Disk “T7” Is Not Connected", detail: "Connect the disk and Mado will verify access before restoring your place.",
        waiting: "Waiting for the disk…", reselect: "Choose Folder Again…", chooseOther: "Choose Another Folder…")
}

@MainActor private func waitingPulse(_ view: LostAccessStateView) -> CAKeyframeAnimation? {
    view.waitingDot.layer?.animationKeys()?.compactMap { view.waitingDot.layer?.animation(forKey: $0) as? CAKeyframeAnimation }.first
}

@Test @MainActor func t229LostAccessWaitingPulseMatchesPinnedTimingWithoutLayoutRestart() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    view.display(cause: .diskNotConnected, text: waitingText())
    view.layoutSubtreeIfNeeded()
    let pulse = try #require(waitingPulse(view))
    #expect(pulse.keyPath == "opacity")
    #expect(pulse.values as? [Double] == [1, 0.3, 1])
    #expect(pulse.keyTimes == [0, 0.5, 1])
    #expect(pulse.duration == 1.6)
    #expect(pulse.repeatCount == .infinity)
    #expect(pulse.beginTime > 0)
    let timings = try #require(pulse.timingFunctions)
    #expect(timings.count == 2)
    for timing in timings {
        var first: [Float] = [0, 0]
        var second: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &first)
        timing.getControlPoint(at: 2, values: &second)
        #expect(abs(first[0] - 0.42) < 0.001 && first[1] == 0)
        #expect(abs(second[0] - 0.58) < 0.001 && second[1] == 1)
    }
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    #expect(waitingPulse(view)?.beginTime == pulse.beginTime)
    #expect(view.waitingDot.layer?.opacity == 1)
}

@Test @MainActor func t229LostAccessWaitingPulseRespondsToLiveMotionAndVisibility() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = container
    let view = LostAccessStateView(frame: container.bounds)
    view.display(cause: .diskNotConnected, text: waitingText())
    #expect(waitingPulse(view) == nil)
    container.addSubview(view)
    try #require(waitingPulse(view) != nil)
    view.reduceMotion = true
    #expect(waitingPulse(view) == nil)
    #expect(view.waitingDot.layer?.opacity == 1)
    view.reduceMotion = false
    #expect(waitingPulse(view) != nil)
    view.isHidden = true
    #expect(waitingPulse(view) == nil)
    view.isHidden = false
    #expect(waitingPulse(view) != nil)
    container.isHidden = true
    #expect(waitingPulse(view) == nil)
    container.isHidden = false
    #expect(waitingPulse(view) != nil)
    view.display(cause: .unknown, text: waitingText())
    #expect(waitingPulse(view) == nil)
    view.display(cause: .diskNotConnected, text: waitingText())
    #expect(waitingPulse(view) != nil)
    view.removeFromSuperview()
    #expect(waitingPulse(view) == nil)
    container.addSubview(view)
    #expect(waitingPulse(view) != nil)
}
