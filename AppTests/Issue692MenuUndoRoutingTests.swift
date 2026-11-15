import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #692 fix r2 (device FAIL, smoke692-20261114 step 5): Edit › Undo/Redo stayed greyed in Annotate Mode because
// NSWindow answers undo:/redo: itself (with its own, empty undo manager) before the action reaches the window
// controller. These tests go through the real responder chain from the focused canvas, not a direct
// validateMenuItem call on the controller.

/// The responder AppKit picks for a nil-targeted action: the first one in the chain from the first responder that
/// responds to it, then the window's delegate.
@MainActor private func chainTarget(_ window: NSWindow, _ action: Selector) -> AnyObject? {
    var responder: NSResponder? = window.firstResponder
    while let current = responder {
        if current.responds(to: action) { return current }
        responder = current.nextResponder
    }
    if let delegate = window.delegate, delegate.responds(to: action) { return delegate }
    return nil
}

/// The Edit-menu item's enabled state as menu validation would compute it through the responder chain.
@MainActor private func menuEnabled(_ window: NSWindow, _ action: Selector) -> Bool {
    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
    guard let target = chainTarget(window, action) else { return false }
    return (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
}

private let undoAction = NSSelectorFromString("undo:")
private let redoAction = NSSelectorFromString("redo:")

@MainActor @Suite(.serialized) struct Issue692MenuUndoRoutingTests {
    @Test(.timeLimit(.minutes(3))) func issue692EditMenuUndoRedoFollowTheMarksThroughTheResponderChain() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let window = try #require(controller.window)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        window.makeFirstResponder(controller.canvas)
        try #require(window.firstResponder === controller.canvas)
        #expect(context.marks().count == 1)
        #expect(chainTarget(window, undoAction) === controller, "Edit › Undo reaches the window controller")
        #expect(menuEnabled(window, undoAction), "one mark drawn: Undo is enabled")
        #expect(!menuEnabled(window, redoAction), "nothing undone: Redo is disabled")

        // The menu action itself, sent through the chain from the canvas.
        #expect(controller.canvas.tryToPerform(undoAction, with: nil))
        #expect(context.marks().isEmpty, "Edit › Undo took the mark back")
        #expect(menuEnabled(window, redoAction), "after Undo, Redo is enabled")
        #expect(!menuEnabled(window, undoAction))
        #expect(controller.canvas.tryToPerform(redoAction, with: nil))
        #expect(context.marks().count == 1, "Edit › Redo put it back")

        // ⌘Z still changes the marks exactly once.
        try context.key("z", code: 6, modifiers: [.command])
        #expect(context.marks().isEmpty, "⌘Z undid once")
        try context.key("z", code: 6, modifiers: [.command, .shift])
        #expect(context.marks().count == 1, "⇧⌘Z redid once")

        // During a held move both are off; after mouse-up they follow the marks again.
        try context.key("v", code: 9)
        try context.click(CGPoint(x: 450, y: 250))
        try context.press(CGPoint(x: 450, y: 250), to: CGPoint(x: 480, y: 290))
        #expect(!menuEnabled(window, undoAction), "Undo is disabled while dragging")
        #expect(!menuEnabled(window, redoAction), "Redo is disabled while dragging")
        try context.release(CGPoint(x: 480, y: 290))
        #expect(menuEnabled(window, undoAction), "Undo is back after mouse-up")
        #expect(!menuEnabled(window, redoAction), "the move cleared Redo")
    }

    @Test(.timeLimit(.minutes(3))) func issue692OutsideAnnotateModeTheWindowKeepsUndoRedo() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let window = try #require(controller.window)
        window.makeFirstResponder(controller.canvas)
        #expect(!controller.session.isAnnotating)
        #expect(chainTarget(window, undoAction) === window, "the viewer keeps NSWindow's own Undo")
        #expect(chainTarget(window, redoAction) === window, "the viewer keeps NSWindow's own Redo")
    }
}

// #692 fix r3 (device FAIL, smoke692-20261114b step 5): while a text mark is typed, ⌘Z and Edit › Undo did
// nothing, because the window declined undo:/redo: in Annotate Mode and the field editor's typing undo is carried
// out by NSWindow's undo:. These go through the real chain from the field editor and AppKit's own validation.

/// Enabled as NSMenu validates it: validateMenuItem(_:) if the target has it, else validateUserInterfaceItem(_:).
@MainActor private func menuValidates(_ window: NSWindow, _ action: Selector) -> Bool {
    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
    guard let target = chainTarget(window, action) else { return false }
    if let validation = target as? NSMenuItemValidation { return validation.validateMenuItem(item) }
    if let validation = target as? NSUserInterfaceValidations { return validation.validateUserInterfaceItem(item) }
    return true
}

@MainActor @Suite(.serialized) struct Issue692TypingUndoTests {
    @Test(.timeLimit(.minutes(3))) func issue692TypingUndoActsOnTheTextNotTheMarks() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let window = try #require(controller.window)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let before = context.marks()
        try #require(before.count == 1)

        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        try context.type("abc")
        let overlay = try context.overlay()
        let field = try #require(overlay.textEditor)
        try #require(overlay.isEditingText && field.stringValue == "abc")
        let editor = try #require(window.firstResponder as? NSTextView, "the field editor is typing")

        #expect(menuValidates(window, undoAction), "Edit › Undo is enabled while the typing can be undone")
        #expect(editor.tryToPerform(undoAction, with: nil), "Undo reaches something from the field editor")
        #expect(field.stringValue == "", "Edit › Undo took the typed characters back")
        #expect(overlay.isEditingText, "the typing goes on")
        #expect(context.marks() == before, "a typing undo leaves the marks alone")
        #expect(menuValidates(window, redoAction), "Edit › Redo is enabled after a typing undo")
        #expect(editor.tryToPerform(redoAction, with: nil))
        #expect(field.stringValue == "abc", "Edit › Redo brought the characters back")
        #expect(context.marks() == before)

        // Ending the text makes Undo act on the marks again: one step takes the whole text mark.
        try context.escape()
        #expect(!overlay.isEditingText)
        #expect(context.marks().count == 2, "Esc committed the text mark")
        window.makeFirstResponder(controller.canvas)
        #expect(chainTarget(window, undoAction) === controller, "after the text ends, Undo is the marks' again")
        #expect(menuValidates(window, undoAction))
        #expect(controller.canvas.tryToPerform(undoAction, with: nil))
        #expect(context.marks() == before, "one Undo took the whole text mark, and only it")
    }
}
