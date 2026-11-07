import AppKit
import SwiftUI
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func chromeRefreshChangesRenderInputAndKeepsAXButtonsAsLeaves() throws {
    _ = NSApplication.shared
    let host = ChromeToolsHost()
    host.hasImage = false
    let session = ViewerSession(host: host)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 960, height: 640), session: session)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = overlay
    defer { window.close() }
    let tool = try #require(overlay.tools.last)
    let visual = try #require(tool.subviews.first as? NSHostingView<ChromeToolFace>)
    #expect(visual.rootView.enabled == false)
    host.hasImage = true
    overlay.refresh(filename: "loaded.png")
    // The native hosting root must change value when an opaque host changes availability.
    #expect(visual.rootView.enabled == true)
    #expect(tool.accessibilityChildren()?.isEmpty == true)
    host.hasImage = false
    overlay.refresh()
    #expect(visual.rootView.enabled == false)
    #expect(tool.acceptsFirstResponder == false)
}
