import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #693 slice B fix round 1, opus M1: a click on the redaction hint's text (it stays shown) never takes the Annotate
// keys from the canvas. The #690 harness: page 39's 1600×2400 image, 1280×800 window.

@MainActor @Suite(.serialized) struct Issue693HintFocusTests {
    @Test(.timeLimit(.minutes(3))) func issue693ClickOnTheHintKeepsAnnotateKeys() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("m", code: 46)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let popover = try context.popover()
        let window = try #require(controller.window)
        // What NSWindow does with a mouse-down on the hint's words: offer it the keys. The hint stays shown.
        _ = window.makeFirstResponder(popover.hintView)
        #expect(!popover.hintView.isHidden)
        #expect(window.firstResponder !== popover.hintView, "the hint does not take the keys")
        try context.key("c", code: 8)
        #expect(controller.session.annotateMode?.tool == .crop, "C still chooses 裁剪")
        try context.key("m", code: 46)
        #expect(controller.session.annotateMode?.tool == .redact)
        try context.key("z", code: 6, modifiers: [.command])
        #expect(context.marks().isEmpty, "⌘Z still undoes the redaction")
    }
}
