import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor final class ChromeViewClock: ViewerClock { var now = 0.0 }
@MainActor final class ChromeRecallViewHost: ViewerSessionHost, ViewerChromeHost {
    weak var overlay: ViewerChromeOverlay?
    weak var canvas: CanvasView?
    var hasImage = true
    var lights = false
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) { if focus == .canvas { canvas?.window?.makeFirstResponder(canvas) } }
    func showInspector(_ visible: Bool) {}
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {
        overlay?.setToolsVisible(toolsVisible); lights = trafficLightsVisible
    }
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool {
        overlay?.focusTool(reverse: reverse, entering: entering) == true
    }
}

@MainActor func chromeKey(_ code: UInt16, _ characters: String, shift: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
        timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeRecallViewBandsAndNativeResponder() throws {
    _ = NSApplication.shared
    let clock = ChromeViewClock()
    let host = ChromeRecallViewHost()
    let session = ViewerSession(clock: clock, host: host)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    let canvas = CanvasView(frame: content.bounds, session: session)
    let overlay = ViewerChromeOverlay(frame: content.bounds, session: session)
    host.overlay = overlay; host.canvas = canvas; session.chromeHost = host
    content.addSubview(canvas); content.addSubview(overlay); window.contentView = content
    canvas.onTab = { session.tab(reverse: $0) }
    defer { window.close() }
    clock.now = 2.5; session.advanceChrome()
    overlay.pointerMoved(NSPoint(x: 480, y: 320))
    #expect(session.chrome.visibility == .hidden)
    overlay.pointerMoved(NSPoint(x: 480, y: 639))
    #expect(host.lights)
    #expect(session.chrome.visibility == .hidden)
    overlay.pointerMoved(NSPoint(x: 480, y: 0))
    #expect(session.chrome.visibility == .visible)
    clock.now = 5; session.advanceChrome()
    window.makeFirstResponder(canvas)
    canvas.keyDown(with: try chromeKey(48, "\t"))
    // #444: 侧栏 and 返回网格 are disabled outside a grid preview, so Tab starts on the first enabled tool.
    let enabled = overlay.tools.filter(\.acceptsFirstResponder)
    #expect(window.firstResponder === enabled.first)
    #expect(session.inspectorFocus.focus == .tools)
    let first = try #require(enabled.first)
    first.keyDown(with: try chromeKey(48, "\t"))
    #expect(window.firstResponder === enabled[1])
    enabled[1].keyDown(with: try chromeKey(48, "\t", shift: true))
    #expect(window.firstResponder === first)
    first.keyDown(with: try chromeKey(48, "\t", shift: true))
    #expect(window.firstResponder === canvas)
    clock.now = 7.5; session.advanceChrome()
    canvas.keyDown(with: try chromeKey(48, "\t", shift: true))
    #expect(window.firstResponder === overlay.tools.last)
    #expect(ViewerChromeOverlay.edgeBandHeight == 32)
}
