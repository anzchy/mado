import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func viewerCanvasHasNoFocusOutlineAfterGridPreview() {
    _ = NSApplication.shared
    let session = ViewerSession()
    let item = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [item], sourceVersion: .init(1), scrollAnchor: item)
    #expect(CommandRouter().route(.preview, from: .key, to: session))
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), session: session)
    canvas.focusRingType = .exterior
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = canvas
    #expect(window.makeFirstResponder(canvas))
    #expect(session.mode == .viewing)
    #expect(window.firstResponder === canvas)
    #expect(canvas.focusRingType == .none)
    #expect(canvas.focusRingMaskBounds == .zero)
    canvas.drawFocusRingMask()
}
