import AppKit
import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func gridWindowIdentityRestoresFolderAfterSuccessfulOrFailedPreview() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-folder", isDirectory: true)
    let image = folder.appendingPathComponent("A.jpg")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
    for previousTitle in ["A.jpg", "Mado"] {
        window.title = previousTitle
        window.representedURL = image
        GridWindowIdentity.showFolder(folder, in: window)
        #expect(window.title == "mado-grid-folder")
        #expect(window.representedURL == folder)
    }
}

@Test @MainActor func nativeGridEntryRetiresCanvasInspectorAndDocumentTogether() throws {
    _ = NSApplication.shared
    let session = ViewerSession()
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), session: session)
    let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
        bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let bitmap = try #require(context.makeImage())
    let image = DecodedImage(image: bitmap, sourcePixelSize: CGSize(width: 4, height: 4),
        revision: FileRevision(byteCount: 64, modificationDate: nil), itemID: .ephemeral(UUID()))
    canvas.install(image)
    #expect(canvas.hasImage)
    session.setInspectorVisible(true)
    session.updateFocus(.textInput)
    let old = URL(fileURLWithPath: "/tmp/old-A.jpg")
    let folder = URL(fileURLWithPath: "/tmp/new-B", isDirectory: true)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.title = old.lastPathComponent
    window.representedURL = old
    GridWindowIdentity.enterFolder(folder, session: session, canvas: canvas, window: window)
    #expect(!canvas.hasImage)
    #expect(session.mode == .browsing)
    #expect(!session.inspectorFocus.isVisible && session.inspectorFocus.focus == .canvas)
    #expect(window.title == "new-B" && window.representedURL == folder)
}
