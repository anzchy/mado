import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5 (device run smoke687b-20261115c, amendments 1 and 2): Annotate entry from the OCR editor (F1), focus
// handoff when a focused OCR surface goes away (F2), the AX press (F3), input-method composition (F5), the panel's
// key loop (F6), typing undo (F7), and the focus/exit/IME matrix.

@MainActor private final class Fix5Harness {
    let context: Issue690Context
    let controller: CanvasWindowController
    let window: NSWindow
    var pendingDismissals: [@MainActor () -> Void] = []
    var text = "Hello"

    init() async throws {
        context = try await Issue690Context()
        controller = try await context.open()
        window = try #require(controller.window)
        controller.recogniseTextAdapter.pasteboard = context.pasteboard
        controller.recogniseTextAdapter.recognise = { [weak self] _, _ in
            let text = await MainActor.run { self?.text ?? "" }
            return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: text.isEmpty)
        }
        controller.recogniseTextAdapter.scheduleNoticeDismiss = { [weak self] _, action in self?.pendingDismissals.append(action) }
    }
    func close() { context.close() }

    var overlay: RecogniseTextOverlay? { window.contentView?.subviews.compactMap { $0 as? RecogniseTextOverlay }.first }
    var editor: RecogniseTextEditor? { controller.recogniseTextAdapter.panelEditor }

    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        window.sendEvent(try event(characters, code: code, modifiers: modifiers))
    }
    func event(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    func commandE() throws -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: try event("e", code: 14, modifiers: [.command])) == true
    }
    /// Setup only: the Inspector and a canvas-focused, OCR-free, non-Annotate window.
    func reset(inspector visible: Bool) async throws {
        if controller.session.isAnnotating {
            try key("\u{1b}", code: 53)
            try await waitUntil("left Annotate Mode") { !self.controller.session.isAnnotating }
        }
        controller.recogniseTextAdapter.leaveForAnnotate()
        pendingDismissals.removeAll()
        controller.session.setInspectorVisible(visible)
        controller.showInspector(visible)
        controller.session.updateFocus(.canvas)
        _ = window.makeFirstResponder(controller.canvas)
    }
    /// View › 识别文字 through menu validation.
    func recognise() async throws {
        #expect(try context.enabled("viewer.recognise-text.menu"), "识别文字 is available")
        try context.perform("viewer.recognise-text.menu")
        try await waitUntil("recognition finished") { self.controller.recogniseTextAdapter.model?.isRunning == false }
    }
    /// Setup only: the notice takes focus the way Tab and VoiceOver give it (round 4 proved both reach it).
    func focusNotice() throws -> RecogniseTextNoticeView {
        let notice = try #require(overlay?.noticeView)
        _ = window.makeFirstResponder(notice)
        #expect(window.firstResponder === notice)
        return notice
    }
    /// Opens the panel with Space on the focused notice.
    func openEditor() throws -> RecogniseTextEditor {
        _ = try focusNotice()
        try key(" ", code: 49)
        let editor = try #require(self.editor)
        #expect(window.firstResponder === editor)
        return editor
    }
    func compose(_ editor: NSTextView) {
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("shang", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func fireDismissals() {
        let actions = pendingDismissals
        pendingDismissals.removeAll()
        for action in actions { action() }
    }
    /// The canvas has the keys in fact and in the Session, so Space, arrows, 0/1 and View › 标注 work without a click.
    func expectCanvasOwnsKeys(_ label: String) throws {
        #expect(window.firstResponder === controller.canvas, "\(label): canvas is first responder")
        #expect(controller.session.inspectorFocus.focus == .canvas, "\(label): Session focus is the canvas")
        if !controller.session.isAnnotating {
            #expect(try context.enabled("annotate.enter.menu"), "\(label): View › 标注 is enabled")
        }
    }
}

// MARK: - F1

/// 5a: the device had the Inspector shown, so the Session recorded the OCR editor as `.textInput` and refused entry.
/// The fix-round-4 test ran with the Inspector hidden, where `InspectorFocus` never records `.textInput`.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5EditorAllowsAnnotateMenuAndShortcutWithInspectorShownOrHidden() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    for visible in [true, false] {
        try await h.reset(inspector: visible)
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
        h.window.contentView?.addSubview(other)
        _ = h.window.makeFirstResponder(other)
        #expect(!h.controller.canEnterAnnotateFromMenu, "Inspector visible=\(visible): another text field still refuses")
        #expect(!(try h.context.enabled("annotate.enter.menu")))
        other.removeFromSuperview()
        for viaShortcut in [false, true] {
            try await h.reset(inspector: visible)
            try await h.recognise()
            let editor = try h.openEditor()
            let label = "Inspector visible=\(visible), \(viaShortcut ? "Command-E" : "View › 标注")"
            #expect(h.window.firstResponder === editor)
            // InspectorFocus records `.textInput` only while the Inspector is shown: the device precondition.
            #expect((h.controller.session.inspectorFocus.focus == .textInput) == visible,
                    "\(label): the Session's view of the editor")
            #expect(try h.context.enabled("annotate.enter.menu"), "\(label): enabled from the OCR editor")
            if viaShortcut { #expect(try h.commandE()) } else { try h.context.perform("annotate.enter.menu") }
            #expect(h.controller.session.isAnnotating, "\(label): Annotate Mode on")
            #expect(h.editor == nil && h.overlay?.noticeView == nil && h.overlay?.panelView == nil, "\(label): OCR closed")
            #expect(h.window.firstResponder === h.controller.canvas)
        }
    }
}

// MARK: - F2

/// 2h: a focused success notice that dismisses itself hands focus to the canvas, so Tab keeps moving.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5FocusedNoticeDismissalReturnsFocusToCanvas() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    for visible in [false, true] {
        try await h.reset(inspector: visible)
        try await h.recognise()
        _ = try h.focusNotice()
        #expect(h.pendingDismissals.count == 1, "the dismissal runs on the injected clock")
        h.fireDismissals()
        #expect(h.overlay?.noticeView == nil)
        try h.expectCanvasOwnsKeys("Inspector visible=\(visible), focused notice timed out")
        try h.key("\t", code: 48)
        #expect(h.window.firstResponder is NSView && h.window.firstResponder !== h.controller.canvas,
                "Inspector visible=\(visible): Tab moves on from the canvas")
    }
    // An unrelated control keeps its focus when an unfocused notice times out.
    try await h.reset(inspector: true)
    try await h.recognise()
    let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
    h.window.contentView?.addSubview(other)
    defer { other.removeFromSuperview() }
    _ = h.window.makeFirstResponder(other)
    let responder = h.window.firstResponder
    h.fireDismissals()
    #expect(h.overlay?.noticeView == nil)
    #expect(h.window.firstResponder === responder, "focus elsewhere is not taken")
}

/// 2h widened: a focused panel that a new recognition replaces, or that an image change clears, hands focus to the
/// canvas through the Session; both remove the panel's key wrapper.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5FocusedPanelRemovalReturnsFocusToCanvas() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    for visible in [false, true] {
        try await h.reset(inspector: visible)
        try await h.recognise()
        _ = try h.openEditor()
        h.text = "Again \(visible)"
        try await h.recognise()
        #expect(h.overlay?.panelView == nil && h.overlay?.noticeView != nil, "the new run shows its notice")
        try h.expectCanvasOwnsKeys("Inspector visible=\(visible), panel replaced by a new run")
        #expect(!h.controller.recogniseTextAdapter.hasPanelKeyRouting)

        try await h.reset(inspector: visible)
        try await h.recognise()
        _ = try h.openEditor()
        let before = h.controller.session.imageLoader.fileURL
        let command = before?.lastPathComponent == h.context.first.lastPathComponent ? "command.next.menu" : "command.previous.menu"
        #expect(try h.context.enabled(command))
        try h.context.perform(command)
        try await waitUntil("the other image is shown", timeout: .seconds(60)) {
            h.controller.session.imageLoader.fileURL != before && h.controller.session.imageStatus == .showing
                && h.editor == nil
        }
        try h.expectCanvasOwnsKeys("Inspector visible=\(visible), panel cleared by an image change")
        #expect(!h.controller.recogniseTextAdapter.hasPanelKeyRouting, "the panel's Esc wrapper is gone")
        // A bare arrow navigates again without a canvas click (CommandRouter refuses bare keys, Space and 0/1 too,
        // only while the Session focus is `.textInput`).
        let shown = h.controller.session.imageLoader.fileURL
        let right = shown?.lastPathComponent == h.context.first.lastPathComponent
        let arrow = String(Character(UnicodeScalar(UInt16(right ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey))!))
        try h.key(arrow, code: right ? 124 : 123)
        try await waitUntil("Inspector visible=\(visible): the arrow key navigates", timeout: .seconds(60)) {
            h.controller.session.imageLoader.fileURL != shown && h.controller.session.imageStatus == .showing
        }
    }
}
