import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func t229LostAccessRejectsArchivedViewConstruction() {
    // Recovery controls require the programmatic initializer's complete native composition.
    let archive = NSKeyedArchiver(requiringSecureCoding: false)
    #expect(LostAccessStateView(coder: archive) == nil)
    archive.finishEncoding()
}

@MainActor private func controlScene(_ theme: DesignTheme) -> (NSWindow, LostAccessStateView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    view.display(cause: .unknown, text: .init(title: "Unable to Access This Folder",
        detail: "Choose this folder again, or choose another folder to continue.",
        waiting: "Waiting for the disk…", reselect: "Choose Folder Again…", chooseOther: "Choose Another Folder…"))
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

@Test @MainActor func t229LostAccessNativeFocusMaskPaintsRoundedControl() throws {
    let (window, view) = controlScene(.light)
    defer { window.close() }
    for button in view.buttons {
        #expect(button.focusRingType == .exterior)
        #expect(button.focusRingMaskBounds == button.bounds)
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(button.bounds.width)), pixelsHigh: Int(ceil(button.bounds.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: pixels))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(button.bounds)
        NSColor.white.setFill()
        button.drawFocusRingMask()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let center = try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2))
        let corner = try #require(pixels.colorAt(x: 0, y: 0))
        #expect(center.alphaComponent > 0.99)
        #expect(corner.alphaComponent < 0.01)
        #expect(pixels.pixelsWide > 30 && pixels.pixelsHigh >= 30)
    }
}

@MainActor private func expectControlFill(_ button: NSButton, _ expected: PinnedDesign.Color) throws {
    let fill = try #require(button.layer?.backgroundColor)
    let actual = try #require(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
    #expect(abs(actual.redComponent - expected.red) < 0.001)
    #expect(abs(actual.greenComponent - expected.green) < 0.001)
    #expect(abs(actual.blueComponent - expected.blue) < 0.001)
    #expect(abs(actual.alphaComponent - expected.alpha) < 0.001)
}

@Test(arguments: [DesignTheme.light, .dark]) @MainActor
func t229LostAccessPrimaryHoverTracksPointerAndRestoresThemeFill(_ theme: DesignTheme) throws {
    let (window, view) = controlScene(theme)
    defer { window.close() }
    let button = view.reselectButton
    let page = try PinnedDesign.page("permission-denied")
    let selector = theme == .dark ? ".theme-dark" : ".theme-light"
    let normal = try page.color(selector, "--color-accent-fill", viewport: 800)
    let hovered = try page.color(selector, "--color-accent-fill-hover", viewport: 800)
    try expectControlFill(button, normal)
    button.updateTrackingAreas()
    let areas = button.trackingAreas.filter { ($0.owner as AnyObject?) === button && $0.options.contains(.mouseEnteredAndExited) }
    #expect(areas.count == 1)
    #expect(areas.first?.options.contains(.activeInActiveApp) == true)
    #expect(areas.first?.options.contains(.inVisibleRect) == true)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    button.mouseEntered(with: entered)
    try expectControlFill(button, hovered)
    // Resizing replaces the pointer tracking area without stacking duplicate hover handlers.
    button.frame.size.width += 20
    button.updateTrackingAreas()
    let resizedAreas = button.trackingAreas.filter { ($0.owner as AnyObject?) === button && $0.options.contains(.mouseEnteredAndExited) }
    #expect(resizedAreas.count == 1)
    #expect(resizedAreas.first !== areas.first)
    let exited = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
    button.mouseExited(with: exited)
    try expectControlFill(button, normal)
}
