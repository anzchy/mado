import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func chromeDragPolicyEnablesStripWithoutMakingCanvasDraggable() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let session = ViewerSession()
    let canvas = CanvasView(frame: window.contentView!.bounds, session: session)
    let strip = ChromeDragStrip(frame: NSRect(x: 0, y: 612, width: 960, height: 28))
    window.contentView?.addSubview(canvas); window.contentView?.addSubview(strip)
    ChromeTitlebarPolicy.apply(to: window, visible: false, fullScreen: false)
    #expect(window.isMovableByWindowBackground == true)
    #expect(strip.mouseDownCanMoveWindow == true)
    #expect(canvas.mouseDownCanMoveWindow == false)
    #expect(window.contentView?.hitTest(NSPoint(x: 480, y: 320)) === canvas)
}
