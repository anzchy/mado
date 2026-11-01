import AppKit

/// Preserve panel focus when the pre-session open path requests canvas focus.
final class CommandWindow: NSWindow {
    var preserveResponder: ((NSResponder?) -> Bool)?
    var didChangeResponder: (() -> Void)?
    var consumeKey: ((NSEvent) -> Bool)?
    /// Sees every mouse-down before it is delivered; it cannot swallow the click.
    var observeMouseDown: ((NSEvent) -> Void)?
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
