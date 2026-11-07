import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

/// #238: 「读取失败」 (24F-A) controls behave like page 26's: rounded focus mask, pinned hover fill, no archive.
@Test @MainActor func readFailedRejectsArchivedViewConstruction() {
    let archive = NSKeyedArchiver(requiringSecureCoding: false)
    #expect(ReadFailedStateView(coder: archive) == nil)
    archive.finishEncoding()
}

@MainActor private func readFailedControlScene(_ theme: DesignTheme) -> (NSWindow, ReadFailedStateView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    let view = ReadFailedStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    view.display(.init(title: "Couldn't finish reading “待整理”", detail: "Reading stopped partway.",
        retry: "Retry", chooseOther: "Choose Another Folder…"))
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

@Test @MainActor func readFailedFocusMaskPaintsRoundedControl() throws {
    let (window, view) = readFailedControlScene(.light)
    defer { window.close() }
    for button in view.buttons {
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
        #expect(center.alphaComponent > 0.99 && corner.alphaComponent < 0.01)
    }
}

@MainActor private func readFailedFill(_ button: NSButton, _ expected: PinnedDesign.Color) throws {
    let fill = try #require(button.layer?.backgroundColor)
    let actual = try #require(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
    #expect(abs(actual.redComponent - expected.red) < 0.001)
    #expect(abs(actual.greenComponent - expected.green) < 0.001)
    #expect(abs(actual.blueComponent - expected.blue) < 0.001)
}

@Test(arguments: [DesignTheme.light, .dark]) @MainActor
func readFailedRetryHoverTracksPointerAndRestoresThemeFill(_ theme: DesignTheme) throws {
    let (window, view) = readFailedControlScene(theme)
    defer { window.close() }
    let button = view.retryButton
    let page = try PinnedDesign.page("folder-loading")
    let selector = theme == .dark ? ".theme-dark" : ".theme-light"
    let normal = try page.color(selector, "--color-accent-fill", viewport: 800)
    let hovered = try page.color(selector, "--color-accent-fill-hover", viewport: 800)
    try readFailedFill(button, normal)
    button.updateTrackingAreas()
    let areas = button.trackingAreas.filter { ($0.owner as AnyObject?) === button && $0.options.contains(.mouseEnteredAndExited) }
    #expect(areas.count == 1)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
    button.mouseEntered(with: entered)
    try readFailedFill(button, hovered)
    button.frame.size.width += 20
    button.updateTrackingAreas()
    #expect(button.trackingAreas.filter { ($0.owner as AnyObject?) === button && $0.options.contains(.mouseEnteredAndExited) }.count == 1)
    let exited = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
    button.mouseExited(with: exited)
    try readFailedFill(button, normal)
}

@Test(arguments: [(1280.0, 48.0), (1000.0, 40.0)])
@MainActor func readFailedLayoutWithoutWindowUsesItsOwnWidth(width: Double, inset: Double) {
    // Off-window, the page's own width picks the narrow or wide side inset (page 26's rule).
    let view = ReadFailedStateView(frame: NSRect(x: 0, y: 0, width: width, height: 680))
    view.display(.init(title: "Couldn't finish reading “待整理”", detail: "Reading stopped partway.",
        retry: "Retry", chooseOther: "Choose Another Folder…"))
    view.layoutSubtreeIfNeeded()
    #expect(view.window == nil)
    #expect(abs(view.titleLabel.frame.width - (width - 2 * inset)) < 0.5)
    #expect(abs(view.titleLabel.frame.midX - width / 2) < 0.5)
}
