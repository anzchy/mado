import AppKit
import SwiftUI
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@Test @MainActor func chromeToolsRenderAndActivateWithKeyboard() throws {
    _ = NSApplication.shared
    let effects = ChromeToolsHost()
    let clock = ChromeViewClock()
    let session = ViewerSession(clock: clock, host: effects)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 960, height: 640), session: session)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = overlay
    defer { window.close() }
    // #444: page 14's leading pod has no 打开 tool; 侧栏 is disabled without a folder, so 上一张 is the routed tool.
    let first = overlay.tools[3]
    #expect(!first.mouseDownCanMoveWindow)
    #expect(!overlay.focusTool(reverse: false, entering: false))
    overlay.setToolsVisible(false)
    #expect(!overlay.focusTool(reverse: false, entering: true))
    overlay.setToolsVisible(true)
    #expect(overlay.focusTool(reverse: false, entering: true))
    first.keyDown(with: try chromeKey(49, " "))
    #expect(effects.navigation == [.previous])
    first.keyDown(with: try chromeKey(0, "x"))
    #expect(effects.navigation == [.previous])
    first.keyDown(with: try chromeKey(53, "\u{1b}"))
    #expect(session.inspectorFocus.focus == .canvas)
    #expect(first.focusRingMaskBounds == first.bounds)
    let bitmap = try #require(first.bitmapImageRepForCachingDisplay(in: first.bounds))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    first.drawFocusRingMask()
    NSGraphicsContext.restoreGraphicsState()
    effects.hasImage = false
    let disabled = try #require(overlay.tools.last)
    #expect(!disabled.becomeFirstResponder())
    effects.hasImage = true
    for dark in [false, true] {
        // #444: the leading pod's intent and 更多 faces render beside the base command faces.
        let kinds: [ChromeToolKind] = [.intent(.toggleSidebar), .intent(.returnToGrid), .more, .command(.open),
            .command(.inspector), .command(.previous), .command(.next), .command(.zoomOut), .command(.actualPixels), .command(.zoomIn)]
        for kind in kinds {
            for mode in 0..<3 {
                if mode == 0 { session.beginCanvasImage() }
                if mode == 1 { CommandRouter().route(.actualPixels, from: .button, to: session) }
                if mode == 2 { session.reportCanvasZoom(1.25) }
                let renderer = ImageRenderer(content: ChromeToolFace(session: session, kind: kind, enabled: true, action: {})
                    .frame(width: 160, height: 40).background(DesignColor.canvasBackground.color)
                    .environment(\.colorScheme, dark ? .dark : .light))
                #expect(try #require(renderer.cgImage).width == 160)
            }
        }
    }
    // #444: the 缩放模式 control opens its mode menu instead of toggling; 适应窗口 routes fit.
    let scale = overlay.tools[6]
    let presenter = RecordingMenuPresenter()
    presenter.choose = 0
    overlay.menuPresenter = presenter
    CommandRouter().route(.actualPixels, from: .button, to: session)
    #expect(scale.command == .actualPixels)
    scale.activate()
    #expect(session.zoomMode == .fit)
    overlay.pointerMoved(NSPoint(x: -1, y: -1))
    #expect(overlay.tools[6].toolTip == "Zoom mode")
}
