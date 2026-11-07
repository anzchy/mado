import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func chromeWindowTitlebarDragAndCanvasIsolation() throws {
    _ = NSApplication.shared
    let clock = ChromeViewClock()
    let host = ChromeRecallViewHost()
    let session = ViewerSession(clock: clock, host: host)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "actual-file.png"
    window.titlebarAppearsTransparent = true
    let content = NSView(frame: window.contentView!.bounds)
    let canvas = CanvasView(frame: content.bounds, session: session)
    let overlay = ViewerChromeOverlay(frame: content.bounds, session: session)
    let strip = ChromeDragStrip(frame: NSRect(x: 0, y: content.bounds.height - 28, width: content.bounds.width, height: 28))
    content.addSubview(canvas); content.addSubview(strip); content.addSubview(overlay)
    window.contentView = content
    host.overlay = overlay; host.canvas = canvas; session.chromeHost = host
    defer { window.close() }
    let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    canvas.install(DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 800, height: 400)))
    var requests = 0
    canvas.onResolutionNeeded = { _ in requests += 1 }
    let originalFrame = canvas.frame
    #expect(strip.mouseDownCanMoveWindow)
    #expect(!canvas.mouseDownCanMoveWindow)
    for visible in [false, true, false] {
        overlay.setToolsVisible(visible)
        ChromeTitlebarPolicy.apply(to: window, visible: visible, fullScreen: false)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(try #require(window.standardWindowButton(kind)).isHidden == !visible)
        }
        #expect(window.titleVisibility == (visible ? .visible : .hidden))
        #expect(window.title == "actual-file.png")
        #expect(canvas.frame == originalFrame)
        #expect(!strip.isHidden)
    }
    clock.now = 2.5; session.advanceChrome()
    #expect(!host.lights)
    session.pointerMoved(in: .top)
    #expect(host.lights)
    ChromeTitlebarPolicy.apply(to: window, visible: false, fullScreen: true)
    #expect(try #require(window.standardWindowButton(.closeButton)).isHidden == false)
    #expect(window.titleVisibility == .visible)
    #expect(canvas.frame == originalFrame)
    #expect(requests == 0)
}
