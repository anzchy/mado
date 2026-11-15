import AppKit
import Testing
import MadoApplication

@MainActor private func fix4Start(_ controller: CanvasWindowController, text: String) async throws -> RecogniseTextOverlay {
    controller.recogniseTextAdapter.recognise = { _, _ in
        TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: text.isEmpty)
    }
    controller.recogniseText()
    for _ in 0..<200 {
        if controller.recogniseTextAdapter.model?.isRunning == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(controller.window?.contentView?.subviews.compactMap { $0 as? RecogniseTextOverlay }.first)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix4SuccessNoticeJoinsKeyboardAndAXFocusLoop() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    controller.recogniseTextAdapter.pasteboard = context.pasteboard
    let window = try #require(controller.window)
    let overlay = try await fix4Start(controller, text: "Hello")
    let notice = try #require(overlay.noticeView)
    for visible in [true, false] {
        controller.session.setInspectorVisible(visible)
        controller.showInspector(visible)
        _ = window.makeFirstResponder(controller.canvas)
        var reached = false
        for _ in 0..<20 {
            window.selectNextKeyView(nil)
            if window.firstResponder === notice { reached = true; break }
        }
        #expect(reached, "Tab must reach success notice when Inspector visible=\(visible)")
        window.selectKeyView(following: notice)
        #expect(window.firstResponder !== notice)
        window.selectPreviousKeyView(nil)
        #expect(window.firstResponder === notice, "Shift-Tab must reach the notice from its successor")
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        window.sendEvent(tab)
        #expect(visible ? (window.firstResponder as? NSView)?.accessibilityIdentifier() == "inspector.close"
                        : window.firstResponder === controller.canvas)
    }
    _ = window.makeFirstResponder(controller.canvas)
    notice.setAccessibilityFocused(true)
    #expect(window.firstResponder === notice)
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    window.sendEvent(space)
    #expect(controller.recogniseTextAdapter.panelEditor != nil)
    #expect(window.firstResponder === controller.recogniseTextAdapter.panelEditor)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix4WarningHasNoAXPress() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let overlay = try await fix4Start(controller, text: "")
    let notice = try #require(overlay.noticeView)
    #expect(!notice.acceptsFirstResponder)
    #expect(!notice.accessibilityActionNames().contains(.press))
    #expect(!notice.responds(to: NSSelectorFromString("accessibilityPerformPress")))
    let window = try #require(controller.window)
    _ = window.makeFirstResponder(controller.canvas)
    for _ in 0..<20 {
        window.selectNextKeyView(nil)
        #expect(window.firstResponder !== notice)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix4ReturnOpensFocusedNotice() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let window = try #require(controller.window)
    let overlay = try await fix4Start(controller, text: "Hello")
    let notice = try #require(overlay.noticeView)
    _ = window.makeFirstResponder(notice)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    window.sendEvent(enter)
    #expect(window.firstResponder === controller.recogniseTextAdapter.panelEditor)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix4PanelEditorAllowsAnnotateMenuAndShortcut() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    controller.recogniseTextAdapter.pasteboard = context.pasteboard
    let window = try #require(controller.window)
    let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
    window.contentView?.addSubview(other)
    _ = window.makeFirstResponder(other)
    #expect(!controller.canEnterAnnotateFromMenu, "other text inputs keep the old refusal")
    _ = window.makeFirstResponder(controller.canvas)
    other.removeFromSuperview()
    let overlay = try await fix4Start(controller, text: "Hello")
    let notice = try #require(overlay.noticeView)
    #expect(notice.accessibilityPerformPress())
    // #687 fix r5: the press opens the panel on the next main-actor turn.
    try await waitUntil("the panel opened") { controller.recogniseTextAdapter.panelEditor != nil }
    #expect(window.firstResponder === controller.recogniseTextAdapter.panelEditor)
    let item = try context.item("annotate.enter.menu")
    #expect(context.menu.validateMenuItem(item), "View › Annotate must be enabled from the OCR editor")
    let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "e",
        charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
    #expect(NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true)
    try context.key("e", code: 14, modifiers: [.command])
    #expect(controller.session.isAnnotating)
    #expect(controller.recogniseTextAdapter.panelEditor == nil)
    #expect(overlay.noticeView == nil && overlay.panelView == nil)
}
