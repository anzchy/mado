import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #692 fix r1 (opus M1): in the window, Esc while the field editor holds marked text (an input method composing
// 「上岸」 in Pinyin) goes to the input method: neither the window's key routing nor the menu's Esc commits the text,
// and typing continues.

@MainActor @Suite(.serialized) struct Issue692MarkedTextEscapeTests {
    @Test(.timeLimit(.minutes(3))) func issue692EscapeWhileComposingKeepsTyping() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.ui.answer = .cancel
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        try context.type("ab")
        let overlay = try context.overlay()
        let editor = try #require(controller.window?.firstResponder as? NSTextView, "the field editor has the keys")
        editor.setMarkedText("shang", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())

        // The menu's Esc is used up (so browsing never sees it) and leaves a composing field alone.
        #expect(controller.routeAnnotateEscape())
        #expect(overlay.isEditingText && context.marks().isEmpty)
        try context.escape()
        #expect(overlay.isEditingText, "editing continues")
        #expect(context.marks().isEmpty, "nothing was committed")
        #expect(controller.session.isAnnotating && context.ui.asked.isEmpty)
        #expect(!editor.hasMarkedText(), "the composition was dropped")
        #expect(overlay.textEditor?.stringValue == "ab")

        // Without marked text, Esc ends the typing as before.
        try context.escape()
        #expect(!overlay.isEditingText)
        #expect(context.marks().map(\.text) == ["ab"])
    }
}
