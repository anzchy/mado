import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #690 (P7-11) WI-5 coverage stage: behaviour of the Annotate views beyond the page-39 rows.

@MainActor private final class RecordingContainer: NSView {
    var received: [String] = []
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { received.append("down") }
    override func rightMouseDown(with event: NSEvent) { received.append("right") }
    override func scrollWheel(with event: NSEvent) { received.append("scroll") }
}

@MainActor private func host(_ size: CGSize = CGSize(width: 1280, height: 800)) -> (RecordingContainer, NSWindow) {
    _ = NSApplication.shared
    let container = RecordingContainer(frame: NSRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.appearance = NSAppearance(named: .aqua)
    return (container, window)
}

@MainActor private func event(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@MainActor private func bytes(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690AnnotateViewsAreNotArchivable() {
    let archive = NSKeyedArchiver(requiringSecureCoding: false)
    #expect(AnnotateStripView(coder: archive) == nil)
    #expect(AnnotationOverlayView(coder: archive) == nil)
    #expect(AnnotateSaveConfirmationView(coder: archive) == nil)
    #expect(AnnotateLeaveSheetView(coder: archive) == nil)
    #expect(AnnotateButton(coder: archive) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690DragShowsTheRectangleBeforeRelease() throws {
    let (container, window) = host()
    defer { window.close() }
    let overlay = AnnotationOverlayView(frame: container.bounds)
    container.addSubview(overlay)
    overlay.transform = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
    overlay.imageSize = CGSize(width: 1600, height: 2400)
    overlay.isActive = true
    overlay.tool = .rectangle
    #expect(!overlay.mouseDownCanMoveWindow, "a drag on the image draws; it never moves the window")
    overlay.mouseDown(with: try event(overlay, .leftMouseDown, CGPoint(x: 400, y: 200)))
    overlay.mouseDragged(with: try event(overlay, .leftMouseDragged, CGPoint(x: 500, y: 300)))
    var p = [Int](repeating: 0, count: 4)
    try bytes(overlay).getPixel(&p, atX: 400, y: 250)
    #expect(p == [220, 38, 38, 255], "the rectangle in progress is drawn in the mark paint: \(p)")
    overlay.mouseUp(with: try event(overlay, .leftMouseUp, CGPoint(x: 500, y: 300)))
    try bytes(overlay).getPixel(&p, atX: 400, y: 250)
    #expect(p[3] == 0, "released without a listener, nothing stays drawn")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690NoToolNeitherDrawsNorSelects() throws {
    let (container, window) = host()
    defer { window.close() }
    let overlay = AnnotationOverlayView(frame: container.bounds)
    container.addSubview(overlay)
    overlay.transform = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
    overlay.imageSize = CGSize(width: 1600, height: 2400)
    overlay.isActive = true
    overlay.tool = nil
    overlay.marks = [AnnotationMark(rect: CGRect(x: 100, y: 100, width: 400, height: 400))]
    var log: [String] = []
    overlay.onAddMark = { _ in log.append("add") }
    overlay.onSelect = { _ in log.append("select") }
    overlay.mouseDown(with: try event(overlay, .leftMouseDown, CGPoint(x: 400, y: 200)))
    overlay.mouseUp(with: try event(overlay, .leftMouseUp, CGPoint(x: 500, y: 300)))
    #expect(log == [])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690SheetScrimSwallowsInput() throws {
    let (container, window) = host()
    defer { window.close() }
    let sheet = AnnotateLeaveSheetView(originalName: "a.jpg", plannedName: "a-annotated.jpg")
    container.addSubview(sheet)
    let corner = CGPoint(x: 20, y: 700)
    #expect(container.hitTest(corner) === sheet.scrim)
    sheet.scrim.mouseDown(with: try event(sheet.scrim, .leftMouseDown, corner))
    sheet.scrim.rightMouseDown(with: try event(sheet.scrim, .rightMouseDown, corner))
    let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
    sheet.scrim.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
    #expect(container.received == [], "nothing behind the sheet sees the input")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690ConfirmationHasPanelBackground() throws {
    let (container, window) = host()
    defer { window.close() }
    let confirmation = AnnotateSaveConfirmationView(fileName: "a-annotated.png")
    container.addSubview(confirmation)
    var p = [Int](repeating: 0, count: 4)
    try bytes(confirmation).getPixel(&p, atX: Int(confirmation.bounds.midX), y: 2)
    let panel = DesignColor.popoverBackground.components(.light).map { Int(($0 * 255).rounded()) }
    #expect(p == panel, "\(p)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690DockedViewsFollowAutoresizingWithoutNotifications() {
    let (container, window) = host()
    defer { window.close() }
    let strip = AnnotateStripView(frame: .zero)
    let confirmation = AnnotateSaveConfirmationView(fileName: "a-annotated.png")
    let sheet = AnnotateLeaveSheetView(originalName: "a.jpg", plannedName: "a-annotated.jpg")
    for view in [strip, confirmation, sheet] as [NSView] { container.addSubview(view) }
    container.postsFrameChangedNotifications = false
    container.autoresizesSubviews = false
    let old = container.frame.size
    container.setFrameSize(NSSize(width: 1440, height: 900))
    #expect(strip.frame.minX == 1220, "nothing moved yet")
    for view in [strip, confirmation, sheet] as [NSView] { view.resize(withOldSuperviewSize: old) }
    #expect(strip.frame == CGRect(x: 1380, y: 196, width: 48, height: 508))
    #expect(abs(confirmation.frame.midX - 688) <= 1)
    #expect(sheet.frame == container.bounds)
}
