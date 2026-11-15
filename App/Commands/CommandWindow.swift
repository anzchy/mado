import AppKit

/// Preserve panel focus when the pre-session open path requests canvas focus.
final class CommandWindow: NSWindow {
    var preserveResponder: ((NSResponder?) -> Bool)?
    var didChangeResponder: (() -> Void)?
    var consumeKey: ((NSEvent) -> Bool)?
    /// Sees every mouse-down before it is delivered; it cannot swallow the click.
    var observeMouseDown: ((NSEvent) -> Void)?
    /// #692 fix r2: NSWindow answers undo:/redo: itself, from its own undo manager, so a nil-targeted
    /// Edit › Undo/Redo never reaches the window controller. While this returns true, the window declines them and
    /// the responder chain carries them on to the controller. While a text mark is typed it returns false, so the
    /// window's undo:/redo: carry out the field editor's typing undo (#692 fix r3).
    var yieldsUndoRedo: (() -> Bool)?
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == Self.undoAction || aSelector == Self.redoAction, yieldsUndoRedo?() == true { return false }
        return super.responds(to: aSelector)
    }
    private static let undoAction = NSSelectorFromString("undo:")
    private static let redoAction = NSSelectorFromString("redo:")
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if preserveResponder?(responder) == true { return false }
        let accepted = super.makeFirstResponder(responder)
        if accepted { didChangeResponder?() }
        return accepted
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, consumeKey?(event) == true { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown { observeMouseDown?(event) }
        super.sendEvent(event)
    }
}
