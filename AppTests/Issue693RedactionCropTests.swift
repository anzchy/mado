import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #693 slice B (P7-11) WI-4: 遮挡 and 裁剪 in the real window (the #690 harness: a 1600×2400 image at page 39's zoom
// 0.32, origin 352,16, 1280×800 window). tests-20261114-i693b.md A1–A6.

private let undoAction = NSSelectorFromString("undo:")
private let redoAction = NSSelectorFromString("redo:")

extension Issue690Context {
    func popover() throws -> AnnotateRedactionOptionsView {
        try #require(views(AnnotateRedactionOptionsView.self).first, "the redaction options are installed")
    }
    var popoverShown: Bool {
        views(AnnotateRedactionOptionsView.self).contains { !$0.isHidden && $0.superview != nil }
    }
    /// The popover's frame in the content view's top-left points.
    func popoverFrame() throws -> CGRect {
        let view = try popover()
        let content = try #require(controller.window?.contentView)
        let frame = view.convert(view.bounds, to: content)
        return content.isFlipped ? frame : CGRect(x: frame.minX, y: content.bounds.height - frame.maxY,
                                                  width: frame.width, height: frame.height)
    }
    func returnKey() throws { try key("\r", code: 36) }
    func crop() -> CGRect? { controller.session.annotateMode?.document.crop }
    func pendingCrop() -> CGRect? { controller.session.annotateMode?.pendingCrop }
    /// The crop a drag between two overlay points gives at page 39's transform.
    func expectedCrop(_ a: CGPoint, _ b: CGPoint) -> CGRect? {
        AnnotationGeometry.cropRect(from: a, to: b, transform: controller.canvas.backdropFrame.transform, imageSize: page39Size)
    }
}

private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.5) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

@MainActor @Suite(.serialized) struct Issue693RedactionCropTests {
    @Test(.timeLimit(.minutes(3))) func issue693MAndCChooseToolsOnlyInAnnotateMode() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        try context.key("m", code: 46)
        try context.key("c", code: 8)
        try await context.settle()
        #expect(!controller.session.isAnnotating, "no letter starts Annotate Mode")
        #expect(controller.session.imageLoader.fileURL == context.first)

        controller.enterAnnotateMode()
        let strip = try context.strip()
        #expect(!context.popoverShown, "the options belong to 遮挡")
        try context.key("m", code: 46)
        #expect(controller.session.annotateMode?.tool == .redact)
        #expect(strip.button(.redact).state == .on)
        #expect(try context.overlay().tool == .redact)
        #expect(context.popoverShown, "遮挡 shows its options")
        try context.key("c", code: 8)
        #expect(controller.session.annotateMode?.tool == .crop)
        #expect(strip.button(.crop).state == .on)
        #expect(!context.popoverShown, "裁剪 hides them")
        try context.key("M", code: 46, modifiers: [.shift])
        #expect(controller.session.annotateMode?.tool == .redact)
        // ⌘C stays Copy, ⌥C/⌃M choose nothing.
        try context.key("c", code: 8, modifiers: [.command])
        try context.key("c", code: 8, modifiers: [.option])
        try context.key("m", code: 46, modifiers: [.control])
        #expect(controller.session.annotateMode?.tool == .redact)

        // Typing in a text mark: m and c are letters.
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        try context.key("m", code: 46)
        try context.key("c", code: 8)
        #expect(try context.overlay().textEditor?.stringValue == "mc")
        #expect(controller.session.annotateMode?.tool == .text)
    }

    @Test(.timeLimit(.minutes(3))) func issue693RedactionDefaultHintAndSwitchToSolid() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let mark = try #require(context.marks().first)
        #expect(mark.kind == .redaction && mark.redaction == .mosaic(strength: 24))
        let popover = try context.popover()
        #expect(popover.style == .mosaic(strength: 24))
        let mosaicFrame = try context.popoverFrame()
        // Page 39's frame is pinned for the Chinese hint (two lines); the English hint wraps to three lines (16.8 pt
        // taller), docked by the same rule (centred on 遮挡 at y 381).
        let chinese = String(localized: "Mosaic") == "马赛克"
        let expected = chinese ? CGRect(x: 972, y: 311, width: 236, height: 139.6)
                               : CGRect(x: 972, y: 303, width: 236, height: 156.4)
        #expect(near(mosaicFrame, expected), "\(mosaicFrame)")
        #expect(!popover.hintView.isHidden, "the weak-mosaic hint shows")
        #expect(popover.solidLine.isHidden)
        // 改用实色块 restyles the selected mark, one undo step.
        _ = popover.textView(popover.hintView, clickedOnLink: "mado-annotate:solid", at: 0)
        #expect(context.marks().first?.redaction == .solid)
        #expect(context.marks().count == 1)
        #expect(popover.style == .solid && popover.hintView.isHidden && !popover.solidLine.isHidden)
        let solidFrame = try context.popoverFrame()
        #expect(near(solidFrame, CGRect(x: 972, y: 332, width: 236, height: 97.8)), "\(solidFrame)")
        #expect(controller.canvas.tryToPerform(undoAction, with: nil))
        #expect(context.marks().first?.redaction == .mosaic(strength: 24), "⌘Z takes the restyle back")
        #expect(popover.style == .mosaic(strength: 24), "the options follow the mark")
        #expect(controller.canvas.tryToPerform(undoAction, with: nil))
        #expect(context.marks().isEmpty, "the drawing was the step before")
    }

    @Test(.timeLimit(.minutes(3))) func issue693StrengthChangeOnASelectedRedaction() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let popover = try context.popover()
        popover.slider.integerValue = 40
        #expect(NSApp.sendAction(try #require(popover.slider.action), to: popover.slider.target, from: popover.slider))
        #expect(context.marks().first?.redaction == .mosaic(strength: 40))
        #expect(controller.session.annotateMode?.redactionStyle == .mosaic(strength: 40))
        #expect(controller.canvas.tryToPerform(undoAction, with: nil))
        #expect(context.marks().first?.redaction == .mosaic(strength: 24))
        #expect(popover.slider.integerValue == 24)
        #expect(controller.canvas.tryToPerform(redoAction, with: nil))
        #expect(context.marks().first?.redaction == .mosaic(strength: 40))
        #expect(popover.slider.integerValue == 40)
    }

    @Test(.timeLimit(.minutes(3))) func issue693CropApplyCancelClearAndUndo() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.ui.answer = .cancel
        // Return with nothing pending changes nothing.
        try context.returnKey()
        #expect(controller.session.annotateMode?.document.canUndo == false)
        try context.key("c", code: 8)
        let a = try #require(context.expectedCrop(CGPoint(x: 400, y: 200), CGPoint(x: 500, y: 300)))
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        #expect(context.pendingCrop() == a && context.crop() == nil, "a drag only proposes the crop")
        #expect(try context.overlay().pendingCrop == a)
        // Esc cancels the proposal and stays.
        try context.escape()
        #expect(context.pendingCrop() == nil && context.crop() == nil)
        #expect(controller.session.isAnnotating && context.ui.asked.isEmpty)
        #expect(controller.session.annotateMode?.document.canUndo == false)
        // Drag, Return: applied, one undo step.
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.returnKey()
        #expect(context.crop() == a && context.pendingCrop() == nil)
        #expect(try context.overlay().crop == a)
        // Another drag outside it, then 完成: replaced, still annotating.
        let b = try #require(context.expectedCrop(CGPoint(x: 600, y: 400), CGPoint(x: 700, y: 600)))
        try context.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 700, y: 600))
        #expect(context.pendingCrop() == b)
        try context.strip().button(.done).performClick(nil)
        #expect(context.crop() == b && context.pendingCrop() == nil)
        #expect(controller.session.isAnnotating && context.ui.asked.isEmpty, "完成 applied the crop instead of leaving")
        // ⌫ clears it.
        try context.backspace()
        #expect(context.crop() == nil)
        // Edit › Undo ×3 then Redo ×3.
        for expected in [b, a, nil] as [CGRect?] {
            #expect(controller.canvas.tryToPerform(undoAction, with: nil))
            #expect(context.crop() == expected)
        }
        for expected in [a, b, nil] as [CGRect?] {
            #expect(controller.canvas.tryToPerform(redoAction, with: nil))
            #expect(context.crop() == expected)
        }
        // ⌫ with another tool deletes the selected mark and keeps the crop.
        #expect(controller.canvas.tryToPerform(undoAction, with: nil))
        try context.key("r", code: 15)
        try context.drag(from: CGPoint(x: 400, y: 500), to: CGPoint(x: 500, y: 600))
        #expect(context.marks().count == 1)
        try context.backspace()
        #expect(context.marks().isEmpty && context.crop() == b)
        // A second 完成 with nothing pending asks about the unsaved crop.
        try context.strip().button(.done).performClick(nil)
        #expect(context.ui.asked == [.escape])
        #expect(controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue693SaveAndCopyUseTheCroppedSize() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        _ = try context.popover().textView(try context.popover().hintView, clickedOnLink: "mado-annotate:solid", at: 0)
        let redaction = try #require(context.marks().first)
        #expect(redaction.redaction == .solid)
        try context.key("c", code: 8)
        try context.drag(from: CGPoint(x: 380, y: 180), to: CGPoint(x: 700, y: 600))
        let crop = try #require(context.pendingCrop())
        // ⌘S applies the pending crop and saves the cropped size.
        try context.perform("annotate.save.menu")
        #expect(context.crop() == crop)
        try await waitUntil("copy saved", timeout: .seconds(60)) { context.ui.saved.count == 1 }
        let copy = try issue690Image(try #require(context.ui.saved.first))
        #expect(copy.width == Int(crop.width) && copy.height == Int(crop.height), "\(copy.width)×\(copy.height) vs \(crop)")
        let inside = redaction.rect.intersection(crop).insetBy(dx: 2, dy: 2)
        for (x, y) in [(inside.minX, inside.minY), (inside.midX, inside.midY), (inside.maxX - 1, inside.maxY - 1)] {
            let p = try issue690Pixel(copy, x: Int(x - crop.minX), y: Int(y - crop.minY))
            #expect(p == [0, 0, 0], "solid redaction at \(x),\(y): \(p)")
        }
        // ⌘C copies the cropped image too.
        try context.key("c", code: 8, modifiers: [.command])
        if !context.pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { controller.copy(nil) }
        try await waitUntil("pasteboard holds an image", timeout: .seconds(60)) {
            context.pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        }
        let copied = try #require(NSImage(pasteboard: context.pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(copied.width == Int(crop.width) && copied.height == Int(crop.height))
        // A pending crop is applied by ⌘C as well.
        context.pasteboard.clearContents()
        // Started outside the applied crop, so the drag proposes a new one instead of moving it.
        let smaller = try #require(context.expectedCrop(CGPoint(x: 720, y: 620), CGPoint(x: 800, y: 700)))
        try context.drag(from: CGPoint(x: 720, y: 620), to: CGPoint(x: 800, y: 700))
        #expect(context.pendingCrop() == smaller)
        controller.copy(nil)
        #expect(context.crop() == smaller && context.pendingCrop() == nil)
        try await waitUntil("pasteboard holds the second image", timeout: .seconds(60)) {
            context.pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        }
        let second = try #require(NSImage(pasteboard: context.pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(second.width == Int(smaller.width) && second.height == Int(smaller.height))
    }

    @Test(.timeLimit(.minutes(3))) func issue693RedactionStringsInChineseAndEnglish() async throws {
        let expected = [("Redact", "遮挡"), ("Crop", "裁剪"), ("Redaction Options", "遮挡选项"), ("Mosaic", "马赛克"),
                        ("Solid", "实色块"), ("Strength", "强度"), ("Mosaic Strength", "马赛克强度"),
                        ("A weak mosaic can be reversed to reveal text; use a solid box for anything truly secret.",
                         "强度低的马赛克可能被还原出文字；真正保密的内容请用实色块。"),
                        ("Use Solid Box", "改用实色块"), ("Solid black box; cannot be reversed.", "纯黑色块，不可还原。")]
        for (key, chinese) in expected {
            #expect(try issue690CatalogValue(key, "en") == key)
            #expect(try issue690CatalogValue(key, "zh-Hans") == chinese, "\(key)")
        }
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        let popover = try context.popover()
        #expect(popover.accessibilityLabel() == String(localized: "Redaction Options"))
        #expect(popover.slider.accessibilityLabel() == String(localized: "Mosaic Strength"))
    }
}
