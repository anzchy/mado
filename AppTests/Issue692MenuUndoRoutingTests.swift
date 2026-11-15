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
