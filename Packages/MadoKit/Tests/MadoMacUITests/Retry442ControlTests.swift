import AppKit
import Testing
@testable import MadoMacUI

@MainActor private func retry442ControlScene() -> (NSWindow, ReadFailedStateView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let page = ReadFailedStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = page
    page.display(.init(title: "Couldn't finish reading “photos”", detail: "Reading stopped partway.",
        retry: "Retry", chooseOther: "Choose Another Folder…"))
    return (window, page)
}

@MainActor private func retry442ControlEvent(_ window: NSWindow, keypad: Bool = false,
    flags: NSEvent.ModifierFlags = [], keyCode: UInt16? = nil,
    type: NSEvent.EventType = .keyDown) throws -> NSEvent {
    let text = keypad ? "\u{3}" : "\r"
    return try #require(NSEvent.keyEvent(with: type, location: .zero,
        modifierFlags: flags.union(keypad ? [.numericPad] : []), timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: text,
        charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode ?? (keypad ? 76 : 36)))
}

/// The window-level integration test also verifies these equivalents beat the actual command menu.
@Test(.timeLimit(.minutes(2)), arguments: [false, true]) @MainActor
func retry442ControlReturnActivatesOnlyTheFocusedAction(keypad: Bool) throws {
    let (window, page) = retry442ControlScene()
    defer { window.close() }
    var actions: [String] = []
    page.onRetry = { actions.append("retry") }
    page.onChooseOtherFolder = { actions.append("choose") }
    let event = try retry442ControlEvent(window, keypad: keypad)
    #expect(window.makeFirstResponder(page.retryButton))
    #expect(!page.chooseOtherButton.performKeyEquivalent(with: event))
    #expect(page.retryButton.performKeyEquivalent(with: event))
    #expect(actions == ["retry"])
    #expect(window.firstResponder === page.retryButton)
    #expect(window.makeFirstResponder(page.chooseOtherButton))
    #expect(!page.retryButton.performKeyEquivalent(with: event))
    #expect(page.chooseOtherButton.performKeyEquivalent(with: event))
    #expect(actions == ["retry", "choose"])
    #expect(window.firstResponder === page.chooseOtherButton)
}

@Test(.timeLimit(.minutes(2))) @MainActor func retry442ControlRejectsExcludedKeyAndControlStates() throws {
    let (window, page) = retry442ControlScene()
    defer { window.close() }
    var actions: [String] = []
    page.onRetry = { actions.append("retry") }
    page.onChooseOtherFolder = { actions.append("choose") }
    #expect(window.makeFirstResponder(page.retryButton))
    for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
        #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window, flags: modifier)))
        #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window, keypad: true, flags: modifier)))
    }
    #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window, keyCode: 0)))
    #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window, type: .keyUp)))
    page.retryButton.isEnabled = false
    #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window)))
    page.retryButton.isEnabled = true
    page.retryButton.isHidden = true
    #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window)))
    page.retryButton.isHidden = false
    page.isHidden = true
    #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window)))
    page.isHidden = false
    #expect(actions.isEmpty)
    page.retryButton.removeFromSuperview()
    #expect(!page.retryButton.performKeyEquivalent(with: try retry442ControlEvent(window)))
    #expect(actions.isEmpty)
}
