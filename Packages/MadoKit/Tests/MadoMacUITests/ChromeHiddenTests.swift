import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func chromeHiddenExcludesHitFocusAndAccessibility() throws {
    _ = NSApplication.shared
    let host = ChromeToolsHost()
    let session = ViewerSession(host: host)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.autorecalculatesKeyViewLoop = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    let canvas = CanvasView(frame: content.bounds, session: session)
    let overlay = ViewerChromeOverlay(frame: content.bounds, session: session)
    overlay.installTestMenus()
    content.addSubview(canvas); content.addSubview(overlay)
    window.contentView = content
    defer { window.close() }
    overlay.linkKeyViews(to: canvas)
    // #444: page 14's leading pod has no 打开 tool; 侧栏 is disabled without a folder, so 上一张 is the routed tool.
    let first = overlay.tools[3]
    let point = first.convert(NSPoint(x: 15, y: 14), to: content)
    #expect(content.hitTest(NSPoint(x: 480, y: 320)) === canvas)
    for visible in [true, false, true] {
        overlay.setToolsVisible(visible)
        #expect(overlay.tools.allSatisfy { $0.isHidden == !visible })
        #expect(overlay.groups.allSatisfy { $0.isHidden == !visible })
        if visible {
            #expect(content.hitTest(point) === first)
            #expect(first.acceptsFirstResponder)
            #expect(canvas.nextValidKeyView === overlay.tools[2])  // 更多 is the first enabled tool
            #expect(window.makeFirstResponder(first))
            #expect(overlay.accessibilityChildren()?.count == 8)
        } else {
            #expect(content.hitTest(point) === canvas)
            #expect(overlay.tools.allSatisfy { !$0.acceptsFirstResponder })
            #expect(canvas.nextValidKeyView !== first)
            #expect(overlay.accessibilityChildren()?.isEmpty == true)
        }
    }
    host.hasImage = false
    overlay.refresh()
    #expect(overlay.tools.last?.acceptsFirstResponder == false)
    #expect(overlay.hitTest(NSPoint(x: -1, y: -1)) == nil)
}
