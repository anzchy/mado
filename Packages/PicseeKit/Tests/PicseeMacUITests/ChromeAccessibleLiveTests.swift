import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@Test @MainActor func chromeAccessibleValueTracksSessionWithoutHostRefresh() throws {
    _ = NSApplication.shared
    let effects = ChromeToolsHost()
    let session = ViewerSession(host: effects)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 680), session: session)
    // #444: page 14 leading pod 侧栏/返回网格/更多 replaces 打开/信息, so tool indices after it shift by one.
    let scale = overlay.tools[6]
    #expect(scale.accessibilityValue() as? String == "Fit window")
    CommandRouter().route(.actualPixels, from: .button, to: session)
    #expect(scale.accessibilityValue() as? String == "1:1 · 100%")
    session.reportCanvasZoom(1.25)
    #expect(scale.accessibilityValue() as? String == "125%")
    CommandRouter().route(.fit, from: .button, to: session)
    #expect(scale.accessibilityValue() as? String == "Fit window")
    // The 侧栏 toggle reports its pressed state (page 14 aria-pressed); the others have no value.
    for tool in overlay.tools where tool !== scale && tool.intent != .toggleSidebar { #expect(tool.accessibilityValue() == nil) }
}
