import AppKit
import SwiftUI
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class MotionSource: ReduceMotionSource {
    var reduceMotion: Bool
    var onChange: (@MainActor () -> Void)?
    init(_ value: Bool) { reduceMotion = value }
    func set(_ value: Bool) { reduceMotion = value; onChange?() }
}

@MainActor private func motionPolicyWindow(_ content: NSView) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 640, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    return window
}

@MainActor private final class MotionProbeView: NSView {
    var duration = -1.0
    var marker: UUID?
}

private struct MotionNativeProbe: NSViewRepresentable {
    let duration: Double
    let marker: UUID
    func makeNSView(context: Context) -> MotionProbeView { MotionProbeView() }
    func updateNSView(_ view: MotionProbeView, context: Context) {
        view.duration = duration
        view.marker = marker
    }
}

private struct MotionComponentProbe: View {
    @Environment(\.designReduceMotion) private var policyMotion
    @State private var marker = UUID()
    var body: some View {
        VStack {
            IconCommandButton(symbol: .info, state: [], theme: .light, action: {})
            MotionNativeProbe(duration: ComponentResolver.transition(reduceMotion: policyMotion), marker: marker)
        }
    }
}

@MainActor private func motionPolicyProbe(in view: NSView) -> MotionProbeView? {
    if let probe = view as? MotionProbeView { return probe }
    for child in view.subviews {
        if let probe = motionPolicyProbe(in: child) { return probe }
    }
    return nil
}

@MainActor private func motionPolicyLayout(_ view: NSView) {
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
}

@Test(.timeLimit(.minutes(2))) @MainActor func motionPolicyInitialAndLiveFlagTransitions() {
    for initial in [false, true] {
        let source = MotionSource(initial)
        let policy = MotionPolicy(source: source)
        #expect(policy.reduceMotion == initial)
        for expected in [true, false, true, true] {
            source.set(expected)
            #expect(policy.reduceMotion == expected)
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func motionPolicyWeakLifetimeAndLateSourceNotification() {
    var source: MotionSource? = MotionSource(true)
    var policy: MotionPolicy? = MotionPolicy(source: source!)
    weak var weakPolicy = policy
    weak var weakSource = source
    policy = nil
    #expect(weakPolicy == nil)
    source?.set(false)
    #expect(source?.reduceMotion == false)
    source = nil
    #expect(weakSource == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func motionPolicyHostedEnvironmentAndLiveState() throws {
    for initial in [false, true] {
        let source = MotionSource(initial)
        let policy = MotionPolicy(source: source)
        let root = MotionPolicyContent(policy: policy) { MotionComponentProbe() }
        let host = NSHostingView(rootView: root)
        let window = motionPolicyWindow(host)
        defer { window.close() }
        motionPolicyLayout(host)
        let probe = try #require(motionPolicyProbe(in: host))
        let marker = try #require(probe.marker)
        #expect(probe.duration == (initial ? 0 : 0.15))
        for reduced in [true, false, true] {
            source.set(reduced)
            motionPolicyLayout(host)
            #expect(motionPolicyProbe(in: host) === probe)
            #expect(probe.marker == marker)
            #expect(probe.duration == (reduced ? 0 : 0.15))
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func motionPolicyNilWrapperPreservesInheritedEnvironment() throws {
    for inherited in [false, true] {
        let host = NSHostingView(rootView: MotionPolicyContent(policy: nil) { MotionComponentProbe() }
            .environment(\.designReduceMotion, inherited))
        let window = motionPolicyWindow(host)
        defer { window.close() }
        motionPolicyLayout(host)
        #expect(try #require(motionPolicyProbe(in: host)).duration == (inherited ? 0 : 0.15))
    }
}

@MainActor private final class MotionClock: ViewerClock { var now = 0.0 }
@MainActor private final class MotionInstantHost: ViewerSessionHost, ViewerChromeHost {
    let inspector = NSView()
    var overlay: ViewerChromeOverlay!
    var hasImage: Bool { false }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) { inspector.isHidden = !visible }
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) { overlay.setToolsVisible(toolsVisible) }
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool { false }
}

@Test(.timeLimit(.minutes(2))) @MainActor func motionPolicyChromeKeepsPolicyOnRefreshAndTogglesSynchronously() throws {
    let source = MotionSource(true)
    let policy = MotionPolicy(source: source)
    let clock = MotionClock()
    let native = MotionInstantHost()
    native.inspector.isHidden = true
    let session = ViewerSession(clock: clock, host: native)
    let content = NSView(frame: .init(x: 0, y: 0, width: 640, height: 400))
    let overlay = ViewerChromeOverlay(frame: content.bounds, session: session, motionPolicy: policy)
    native.overlay = overlay
    content.addSubview(overlay)
    content.addSubview(native.inspector)
    let window = motionPolicyWindow(content)
    defer { window.close() }
    session.chromeHost = native
    session.reportCanvasZoom(2)
    for reduced in [true, false] {
        source.set(reduced)
        overlay.refresh(filename: "image.png")
        for tool in overlay.tools {
            let face = try #require(tool.subviews.first as? NSHostingView<ChromeToolFace>)
            #expect(face.rootView.motionPolicy === policy)
            #expect(face.rootView.motionPolicy?.reduceMotion == reduced)
        }
        session.activity()
        #expect(overlay.groups.allSatisfy { !$0.isHidden })
        clock.now += 3
        session.advanceChrome()
        #expect(overlay.groups.allSatisfy { $0.isHidden })
        session.setInspectorVisible(true)
        #expect(!native.inspector.isHidden)
        #expect(overlay.groups.allSatisfy { !$0.isHidden })
        session.setInspectorVisible(false)
        #expect(native.inspector.isHidden)
        clock.now += 3
        session.advanceChrome()
        #expect(overlay.groups.allSatisfy { $0.isHidden })
        #expect(session.zoomMode == .custom(2))
    }
}
