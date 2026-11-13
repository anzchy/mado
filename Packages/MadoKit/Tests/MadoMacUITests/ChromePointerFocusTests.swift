import AppKit
import SwiftUI
import Testing
import MadoApplication
@testable import MadoMacUI

// Offscreen test application has no activation lifecycle; model the key-window query only.
@MainActor final class ChromeDispatchWindow: NSPanel {
    override var isKeyWindow: Bool { true }
    var preserveResponder: ((NSResponder?) -> Bool)?
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if preserveResponder?(responder) == true { return false }
        return super.makeFirstResponder(responder)
    }
}

@MainActor func chromePointerEvent(_ type: NSEvent.EventType, tool: NSView, number: Int) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type,
        location: tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: tool.window!.windowNumber,
        context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromePointerWindowDispatchReleasesFocusButTabKeepsLock() throws {
    _ = NSApplication.shared
    let clock = ChromeViewClock()
    let host = ChromeRecallViewHost()
    let session = ViewerSession(clock: clock, host: host)
    let window = ChromeDispatchWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 680),
        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: window.contentView!.bounds)
    let canvas = CanvasView(frame: content.bounds, session: session)
    let overlay = ViewerChromeOverlay(frame: content.bounds, session: session)
    // #444: the 缩放模式 tool opens a menu; a real NSMenu popup would block the main actor in tests.
    overlay.menuPresenter = RecordingMenuPresenter()
    content.addSubview(canvas); content.addSubview(overlay); window.contentView = content
    host.canvas = canvas; host.overlay = overlay; session.chromeHost = host
    // Mirror CanvasWindowController's production veto, which a plain NSPanel misses.
    window.preserveResponder = { responder in
        responder === canvas && session.inspectorFocus.focus != .canvas
    }
    canvas.onCommand = { CommandRouter().route($0, from: .key, to: session) }
    canvas.onTab = { session.tab(reverse: $0) }
    overlay.linkKeyViews(to: canvas)
    defer { window.close() }
    window.makeKeyAndOrderFront(nil)
    for tool in overlay.tools.suffix(3) {
        session.activity(); window.makeFirstResponder(canvas)
        session.reportCanvasZoom(2)
        let visual = try #require(tool.subviews.first as? NSHostingView<ChromeToolFace>)
        let event = try chromePointerEvent(.leftMouseDown, tool: tool, number: 1)
        window.sendEvent(event)
        #expect(session.chrome.locks.contains(.pointerPress))
        window.sendEvent(try chromePointerEvent(.leftMouseUp, tool: tool, number: 2))
        #expect(window.firstResponder === canvas)
        #expect(session.inspectorFocus.focus == .canvas)
        #expect(!session.chrome.locks.contains(.keyboardFocus))
        #expect(!session.chrome.locks.contains(.pointerPress))
        #expect(!visual.rootView.state.contains(.keyboardFocused))
        #expect(!visual.rootView.state.contains(.pressed))
        #expect(session.zoomMode != .fit)
        window.sendEvent(try chromeKey(29, "0"))
        #expect(session.zoomMode == .fit)
        let deadline = try #require(session.nextHideDeadline)
        clock.now = deadline - 0.001; session.advanceChrome()
        #expect(session.chrome.visibility == .visible)
        #expect(!tool.isHiddenOrHasHiddenAncestor)
        clock.now = deadline; session.advanceChrome()
        #expect(session.chrome.visibility == .hidden)
        #expect(tool.isHiddenOrHasHiddenAncestor)
    }
    window.sendEvent(try chromeKey(48, "\t", shift: true))
    #expect(window.firstResponder === overlay.tools.last)
    window.sendEvent(try chromeKey(48, "\t", shift: true))
    // #444: page 14 leading pod 侧栏/返回网格/更多 replaces 打开/信息, so tool indices after it shift by one.
    // The 缩放模式 control opens its mode menu; choosing 1:1 keeps the Space path observable.
    let menuPresenter = RecordingMenuPresenter()
    menuPresenter.choose = 1
    overlay.menuPresenter = menuPresenter
    let keyboardTool = overlay.tools[6]
    let visual = try #require(keyboardTool.subviews.first as? NSHostingView<ChromeToolFace>)
    #expect(window.firstResponder === keyboardTool)
    session.reportCanvasZoom(2)
    keyboardTool.mouseUp(with: try chromePointerEvent(.leftMouseUp, tool: keyboardTool, number: 3))
    #expect(window.firstResponder === keyboardTool)
    #expect(session.zoomMode == .custom(2))
    #expect(session.chrome.locks.contains(.keyboardFocus))
    #expect(visual.rootView.state.contains(.keyboardFocused))
    window.sendEvent(try chromeKey(49, " "))
    #expect(session.zoomMode == .actualPixels)
    #expect(window.firstResponder === keyboardTool)
    #expect(session.inspectorFocus.focus == .tools)
    #expect(visual.rootView.state.contains(.keyboardFocused))
    clock.now += 100; session.advanceChrome()
    #expect(session.chrome.visibility == .locked([.keyboardFocus]))
    #expect(window.firstResponder === keyboardTool)
    #expect(!keyboardTool.isHiddenOrHasHiddenAncestor)
}
