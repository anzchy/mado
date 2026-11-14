import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #690 (P7-11) WI-5: page 39 `?saved=1` (B9) and `?sheet=unsaved` (B10).

@MainActor private final class SheetContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private func container(_ size: CGSize = CGSize(width: 1280, height: 800)) -> (SheetContainer, NSWindow) {
    _ = NSApplication.shared
    let container = SheetContainer(frame: NSRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.appearance = NSAppearance(named: .aqua)
    return (container, window)
}

@MainActor private func frameInContainer(_ view: NSView) throws -> CGRect {
    let superview = try #require(view.superview), content = try #require(view.window?.contentView)
    return superview.convert(view.frame, to: content)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690ConfirmationFrame() {
    let (host, window) = container()
    defer { window.close() }
    let confirmation = AnnotateSaveConfirmationView(fileName: "DSC_0342-annotated.jpg")
    host.addSubview(confirmation)
    host.layoutSubtreeIfNeeded()
    let frame = confirmation.frame
    #expect(frame.height == 36 && frame.minY == 12, "\(frame)")
    #expect(abs(frame.midX - 608) <= 1, "centred on the image area, not the window: \(frame)")
    #expect(frame.width > 200 && frame.width < 480, "\(frame)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690ConfirmationFollowsWidth() {
    let (host, window) = container(CGSize(width: 1440, height: 900))
    defer { window.close() }
    let confirmation = AnnotateSaveConfirmationView(fileName: "DSC_0342-annotated.jpg")
    host.addSubview(confirmation)
    host.layoutSubtreeIfNeeded()
    #expect(abs(confirmation.frame.midX - 688) <= 1 && confirmation.frame.minY == 12)
    host.setFrameSize(NSSize(width: 1280, height: 800))
    #expect(abs(confirmation.frame.midX - 608) <= 1 && confirmation.frame.minY == 12)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690ConfirmationContent() throws {
    let (host, window) = container()
    defer { window.close() }
    let confirmation = AnnotateSaveConfirmationView(fileName: "DSC_0342-annotated.jpg")
    host.addSubview(confirmation)
    host.layoutSubtreeIfNeeded()
    #expect(confirmation.messageField.stringValue == "Saved as DSC_0342-annotated.jpg")
    #expect(confirmation.revealButton.title == "Show in Finder")
    #expect(confirmation.closeButton.accessibilityLabel() == "Close")
    #expect(confirmation.accessibilityIdentifier() == "annotate.saved")
    let tick = try #require(AnnotatePaint.confirmationTick.usingColorSpace(.sRGB))
    #expect([tick.redComponent, tick.greenComponent, tick.blueComponent].map { Int(($0 * 255).rounded()) } == [22, 163, 74])
    #expect(confirmation.tick.contentTintColor == AnnotatePaint.confirmationTick)
    // Every piece sits inside the 36-point bar: padding 6 6 6 12, a 24-point button.
    #expect(confirmation.revealButton.frame.height == 24 && confirmation.closeButton.frame.size == CGSize(width: 24, height: 24))
    #expect(confirmation.closeButton.frame.maxX == confirmation.bounds.width - 6)
    #expect(confirmation.tick.frame.minX == 12)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690ConfirmationButtonsReport() {
    let (host, window) = container()
    defer { window.close() }
    let confirmation = AnnotateSaveConfirmationView(fileName: "a-annotated.png")
    host.addSubview(confirmation)
    var log: [String] = []
    confirmation.onReveal = { log.append("reveal") }
    confirmation.onClose = { log.append("close") }
    confirmation.revealButton.performClick(nil)
    confirmation.closeButton.performClick(nil)
    #expect(log == ["reveal", "close"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690SheetFrameAndScrim() throws {
    let (host, window) = container()
    defer { window.close() }
    let sheet = AnnotateLeaveSheetView(originalName: "DSC_0342.jpg", plannedName: "DSC_0342-annotated.jpg")
    host.addSubview(sheet)
    host.layoutSubtreeIfNeeded()
    #expect(sheet.frame == host.bounds)
    #expect(try frameInContainer(sheet.scrim) == host.bounds)
    let panel = try frameInContainer(sheet.panel)
    #expect(panel.width == 400 && panel.minY == 0 && panel.midX == 640, "\(panel)")
    #expect(panel.height >= 138 && panel.height <= 143, "page 39 measures 142: \(panel.height)")
    let rep = try #require(sheet.scrim.bitmapImageRepForCachingDisplay(in: sheet.scrim.bounds))
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    sheet.scrim.cacheDisplay(in: sheet.scrim.bounds, to: rep)
    let color = srgbPixel(rep, 5, 5)
    let expected = DesignColor.scrim.components(.light)
    #expect(abs(color[3] - expected[3]) <= 2.0 / 255, "\(color)")
    #expect(abs(color[0] / 255 - expected[0]) <= 3.0 / 255 && abs(color[2] / 255 - expected[2]) <= 3.0 / 255, "\(color)")
    host.setFrameSize(NSSize(width: 1440, height: 900))
    #expect(try sheet.frame == host.bounds && frameInContainer(sheet.panel).midX == 720)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690SheetButtonsOrderAndPrimary() throws {
    let (host, window) = container()
    defer { window.close() }
    let sheet = AnnotateLeaveSheetView(originalName: "DSC_0342.jpg", plannedName: "DSC_0342-annotated.jpg")
    host.addSubview(sheet)
    host.layoutSubtreeIfNeeded()
    let buttons = [sheet.discardButton, sheet.cancelButton, sheet.saveButton].sorted { $0.frame.minX < $1.frame.minX }
    #expect(buttons.map(\.title) == ["Don't Save", "Cancel", "Save"])
    #expect(sheet.discardButton.frame.minX == 20)
    #expect(sheet.saveButton.frame.maxX == sheet.panel.bounds.width - 20)
    #expect(sheet.cancelButton.frame.maxX + 8 == sheet.saveButton.frame.minX)
    #expect([sheet.discardButton, sheet.cancelButton, sheet.saveButton].allSatisfy { $0.frame.height == 28 })
    #expect(sheet.saveButton.keyEquivalent == "\r")
    #expect(sheet.cancelButton.keyEquivalent == "\u{1b}")
    let rep = try #require(sheet.panel.bitmapImageRepForCachingDisplay(in: sheet.panel.bounds))
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    sheet.panel.cacheDisplay(in: sheet.panel.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / sheet.panel.bounds.width
    let save = sheet.saveButton.frame
    let p = srgbPixel(rep, Int((save.minX + 3) * scale), Int(save.midY * scale))
    let accent = DesignColor.primaryFill.components(.light)
    #expect(abs(p[0] / 255 - accent[0]) <= 2.0 / 255 && abs(p[2] / 255 - accent[2]) <= 2.0 / 255, "\(p)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690SheetChoices() {
    let (host, window) = container()
    defer { window.close() }
    let sheet = AnnotateLeaveSheetView(originalName: "DSC_0342.jpg", plannedName: "DSC_0342-annotated-2.jpg")
    host.addSubview(sheet)
    var choices: [AnnotateLeaveChoice] = []
    sheet.onChoice = { choices.append($0) }
    sheet.discardButton.performClick(nil)
    sheet.cancelButton.performClick(nil)
    sheet.saveButton.performClick(nil)
    #expect(choices == [.discard, .cancel, .save])
    #expect(sheet.titleField.stringValue.contains("DSC_0342.jpg"))
    #expect(sheet.bodyField.stringValue.contains("DSC_0342-annotated-2.jpg"))
    #expect(sheet.panel.accessibilityRole() == .sheet || sheet.panel.accessibilityRole() == .group)
    #expect(sheet.accessibilityIdentifier() == "annotate.leave-sheet")
}

/// #690 fix r1: the sheet names the copy 存储 will write; a fresh plan replaces the name in place.
@Test(.timeLimit(.minutes(2))) @MainActor func issue690SheetPlannedNameUpdates() {
    let sheet = AnnotateLeaveSheetView(originalName: "DSC_0342.jpg", plannedName: "DSC_0342-annotated.jpg")
    #expect(sheet.plannedName == "DSC_0342-annotated.jpg")
    sheet.plannedName = "DSC_0342-annotated-3.jpg"
    #expect(sheet.bodyField.stringValue.contains("DSC_0342-annotated-3.jpg"))
    #expect(!sheet.bodyField.stringValue.contains("DSC_0342-annotated.jpg"))
    #expect(sheet.titleField.stringValue.contains("DSC_0342.jpg"))
}
