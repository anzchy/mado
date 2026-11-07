import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func chromeAccessibilityPressRoutesOnlyVisibleEnabledTools() throws {
    _ = NSApplication.shared
    let host = ChromeToolsHost()
    let session = ViewerSession(host: host)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 960, height: 640), session: session)
    // #444: page 14's leading pod has no 打开 tool, so the routed tool is 上一张.
    let first = overlay.tools[3]
    #expect(first.accessibilityLabel() == "Previous image")
    #expect(first.accessibilityPerformPress())
    #expect(host.navigation == [.previous])
    overlay.setToolsVisible(false)
    #expect(!first.accessibilityPerformPress())
    #expect(host.navigation == [.previous])
    overlay.setToolsVisible(true)
    host.hasImage = false
    #expect(try #require(overlay.tools.last).accessibilityPerformPress() == false)
    #expect(host.entries.isEmpty)
}
