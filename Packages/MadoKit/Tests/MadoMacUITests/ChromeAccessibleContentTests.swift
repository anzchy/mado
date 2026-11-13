import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func chromeAccessibleScaleAndFilenameUpdateWithoutDuplicateActions() throws {
    _ = NSApplication.shared
    let effects = ChromeToolsHost()
    let session = ViewerSession(host: effects)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 680), session: session)
    let filename = String(repeating: "full-long-name-", count: 30) + ".png"
    // #444: page 14 leading pod 侧栏/返回网格/更多 replaces 打开/信息, so tool indices after it shift by one.
    let scale = overlay.tools[6]
    for (mode, value) in [(0, "Fit window"), (1, "1:1 · 100%"), (2, "125%")] {
        if mode == 0 { session.beginCanvasImage() }
        if mode == 1 { CommandRouter().route(.actualPixels, from: .button, to: session) }
        if mode == 2 { session.reportCanvasZoom(1.25) }
        overlay.refresh(filename: filename)
        overlay.setToolsVisible(true)
        #expect(scale.accessibilityValue() as? String == value)
        #expect(scale.accessibilityChildren()?.isEmpty == true)
        let children = try #require(overlay.accessibilityChildren())
        #expect(children.count == 9)
        let text = try #require(children.compactMap { $0 as? NSTextField }.first)
        #expect(text.accessibilityRole() == .staticText)
        #expect(text.accessibilityValue() as? String == filename)
        overlay.setToolsVisible(false)
        #expect(overlay.accessibilityChildren()?.isEmpty == true)
        #expect(text.isHiddenOrHasHiddenAncestor)
    }
    overlay.refresh()
    overlay.setToolsVisible(true)
    #expect(overlay.accessibilityChildren()?.count == 8)  // #444: 侧栏 / 返回网格 / 更多 + ← → + − 缩放模式 +
}
