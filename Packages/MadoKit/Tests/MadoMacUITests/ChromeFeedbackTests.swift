import AppKit
import SwiftUI
import Testing
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func chromeNativePressAndFocusReachSharedComponentRendering() throws {
    _ = NSApplication.shared
    let host = ChromeRecallViewHost()
    let session = ViewerSession(host: host)
    let window = ChromeDispatchWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 680),
        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: window.contentView!.bounds)
    let canvas = CanvasView(frame: content.bounds, session: session)
    let overlay = ViewerChromeOverlay(frame: content.bounds, session: session)
    // #444: the 缩放模式 tool opens a menu; a real NSMenu popup would block the main actor in tests.
    overlay.menuPresenter = RecordingMenuPresenter()
    content.addSubview(canvas); content.addSubview(overlay); window.contentView = content
    host.overlay = overlay; host.canvas = canvas; session.chromeHost = host
    overlay.linkKeyViews(to: canvas)
    defer { window.close() }
    window.makeKeyAndOrderFront(nil)
    // #444: page 14 leading pod 侧栏/返回网格/更多 replaces 打开/信息, so tool indices after it shift by one.
    for tool in [overlay.tools[5], overlay.tools[6]] {
        let visual = try #require(tool.subviews.first as? NSHostingView<ChromeToolFace>)
        window.makeFirstResponder(tool)
        #expect(visual.rootView.state.contains(.keyboardFocused))
        window.makeFirstResponder(canvas)
        #expect(!visual.rootView.state.contains(.keyboardFocused))
        window.sendEvent(try chromePointerEvent(.leftMouseDown, tool: tool, number: 1))
        let held = visual.rootView
        #expect(held.state.contains(.pressed))
        #expect(ComponentResolver.resolve(.icon, state: held.state, theme: .light).background == .selectionFill)
        let heldImage = try #require(ImageRenderer(content: held.frame(width: 160, height: 44)).cgImage)
        window.sendEvent(try chromePointerEvent(.leftMouseUp, tool: tool, number: 2))
        let released = visual.rootView
        #expect(!released.state.contains(.pressed))
        #expect(!released.state.contains(.keyboardFocused))
        #expect(ComponentResolver.resolve(.icon, state: released.state, theme: .light).background == nil)
        let releasedImage = try #require(ImageRenderer(content: released.frame(width: 160, height: 44)).cgImage)
        let heldData = try #require(heldImage.dataProvider?.data) as Data
        let releasedData = try #require(releasedImage.dataProvider?.data) as Data
        #expect(heldData != releasedData)
    }
}
