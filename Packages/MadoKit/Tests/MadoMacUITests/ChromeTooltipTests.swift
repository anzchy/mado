import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func chromeTooltipsNameCommandsAndRenderArrowShortcuts() throws {
    _ = NSApplication.shared
    let effects = ChromeToolsHost()
    let session = ViewerSession(host: effects)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 680), session: session)
    // #444: page 14 tools; 缩放模式 opens a menu, so it names the control without a key.
    #expect(overlay.tools.map(\.toolTip) == ["Show sidebar (⌃⌘S)", "Return to grid (Esc)", "More browse actions", "Previous image (←)", "Next image (→)", "Zoom out (-)", "Zoom mode", "Zoom in (+)"])
    CommandRouter().route(.actualPixels, from: .button, to: session)
    overlay.refresh()
    #expect(overlay.tools[6].toolTip == "Zoom mode")
    overlay.pointerMoved(NSPoint(x: -1, y: -1))
    #expect(overlay.tools[6].toolTip == "Zoom mode")
    #expect(CommandID.previous.shortcutHint == "\u{f702}")
    #expect(CommandID.next.shortcutHint == "\u{f703}")
}
