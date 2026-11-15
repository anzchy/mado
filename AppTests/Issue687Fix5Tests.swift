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
    /// Edit › 撤销 (or the item Command-Z matches) dispatched the way AppKit sends a nil-targeted action to the key
    /// window: the first responder in the chain that answers undo:, validated first. The test host never becomes the
    /// active app, so `NSApp.sendAction(_:to: nil)` has no key window to start from.
    func editMenuUndo(viaShortcut: Bool) throws -> AnyObject? {
        let undo = NSSelectorFromString("undo:")
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let item = try #require(viaShortcut
            ? items.first { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == [.command] }
            : items.first { $0.action == undo })
        #expect(item.action == undo && item.target == nil)
        var responder: NSResponder? = window.firstResponder
        while let current = responder, !current.responds(to: undo) { responder = current.nextResponder }
        let target: AnyObject? = responder ?? (window.delegate?.responds(to: undo) == true ? window.delegate : nil)
        guard let target else { return nil }
        #expect((target as? NSMenuItemValidation)?.validateMenuItem(item)
                ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true, "Undo is enabled")
        _ = target.perform(undo, with: item)
        return target
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

// MARK: - F3

/// AXPress: the press must return while the notice is still in the window; the panel opens on the next main-queue
/// turn. The external AX error code is not observable in-process (the test host is not an AX-trusted client).
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5NoticePressReturnsBeforeTheNoticeIsReplaced() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    try await h.reset(inspector: false)
    try await h.recognise()
    let overlay = try #require(h.overlay)
    let notice = try #require(overlay.noticeView)
    #expect(notice.accessibilityPerformPress())
    #expect(notice.superview === overlay && overlay.noticeView === notice,
            "the pressed element is still in the window when the press returns")
    #expect(overlay.panelView == nil)
    try await waitUntil("the panel opened") { h.editor != nil }
    #expect(h.window.firstResponder === h.editor)
    #expect(notice.superview == nil)
}

// MARK: - F5

/// While the OCR editor composes (an input method's marked text), Esc, Tab, Shift-Tab, Space, Return and Command-E
/// reach the editor first: the panel stays, focus stays, and Esc drops only the composition.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5ComposingEditorKeepsKeysAndPanel() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    for visible in [true, false] {
        try await h.reset(inspector: visible)
        try await h.recognise()
        let editor = try h.openEditor()
        let overlay = try #require(h.overlay)
        let label = "Inspector visible=\(visible)"
        h.compose(editor)
        #expect(editor.hasMarkedText())
        #expect(!h.controller.canEnterAnnotateFromMenu, "\(label): Command-E waits for the composition")
        #expect(!(try h.context.enabled("annotate.enter.menu")))
        #expect(!(try h.context.enabled("command.escape.menu")), "\(label): View › 聚焦画布 leaves the Esc to the input method")
        _ = try h.commandE()
        #expect(!h.controller.session.isAnnotating && overlay.panelView != nil, "\(label): Command-E")
        try h.key("\u{1b}", code: 53)
        #expect(overlay.panelView != nil, "\(label): Esc keeps the panel")
        #expect(h.window.firstResponder === editor)
        #expect(!editor.hasMarkedText(), "\(label): Esc dropped the composition")
        #expect(editor.string == "Hello", "\(label): nothing was committed")
        for (characters, code, flags) in [("\t", UInt16(48), NSEvent.ModifierFlags()), ("\u{19}", UInt16(48), .shift),
                                          (" ", UInt16(49), []), ("\r", UInt16(36), [])] {
            h.compose(editor)
            let focus = h.controller.session.inspectorFocus.focus
            try h.key(characters, code: code, modifiers: flags)
            let key = "\(label), key \(code)\(flags.contains(.shift) ? " shift" : "")"
            #expect(overlay.panelView != nil, "\(key): panel stays")
            #expect(h.window.firstResponder === editor, "\(key): focus stays in the editor")
            #expect(h.controller.session.inspectorFocus.focus == focus, "\(key): no Session traversal")
            if editor.hasMarkedText() { editor.unmarkText() }
        }
        try h.key("\u{1b}", code: 53)
        #expect(overlay.panelView == nil, "\(label): without a composition Esc closes the panel")
        try h.expectCanvasOwnsKeys("\(label), panel closed by Esc")
    }
}

// MARK: - F6

/// Tab moves focus out of the OCR editor (the text is single-purpose, so a Tab is not typed): editor → 拷贝 → 关闭 →
/// (Inspector close when shown) → canvas; Shift-Tab walks back in the same loop. An intentional move to the
/// Inspector is not refused while the panel is open.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5PanelControlsJoinTheKeyLoop() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    for visible in [false, true] {
        try await h.reset(inspector: visible)
        try await h.recognise()
        let editor = try h.openEditor()
        let panel = try #require(h.overlay?.panelView)
        let label = "Inspector visible=\(visible)"
        try h.key("\t", code: 48)
        #expect(h.window.firstResponder === panel.copyButton, "\(label): Tab editor → 拷贝")
        #expect(editor.string == "Hello", "\(label): no tab typed")
        try h.key("\t", code: 48)
        #expect(h.window.firstResponder === panel.closeButton, "\(label): Tab 拷贝 → 关闭")
        try h.key("\t", code: 48)
        if visible {
            #expect((h.window.firstResponder as? NSView)?.accessibilityIdentifier() == "inspector.close",
                    "\(label): Tab 关闭 → Inspector")
            #expect(h.overlay?.panelView != nil, "the panel stays while the Inspector has focus")
        } else {
            try h.expectCanvasOwnsKeys("\(label): Tab 关闭 → canvas")
        }
        try h.key("\u{19}", code: 48, modifiers: [.shift])
        #expect(h.window.firstResponder === panel.closeButton, "\(label): Shift-Tab back to 关闭")
        try h.key("\u{19}", code: 48, modifiers: [.shift])
        #expect(h.window.firstResponder === panel.copyButton, "\(label): Shift-Tab 关闭 → 拷贝")
        try h.key("\u{19}", code: 48, modifiers: [.shift])
        #expect(h.window.firstResponder === editor, "\(label): Shift-Tab 拷贝 → editor")
        try h.key("\u{19}", code: 48, modifiers: [.shift])
        #expect(h.window.firstResponder !== editor && h.overlay?.panelView != nil,
                "\(label): Shift-Tab leaves the editor backwards, panel open")
        #expect(h.controller.focusContext == .tools, "\(label): back to the last viewer control")
    }
}

// MARK: - F7

/// Typing in the OCR editor can be undone with Edit › 撤销 and Command-Z; the undo stack ends with the editor, and in
/// Annotate Mode Command-Z acts on the marks only. The editor is plain text without smart substitutions.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5EditorTypingUndoIsScopedToTheEditor() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    try await h.reset(inspector: true)
    try await h.recognise()
    let editor = try h.openEditor()
    #expect(editor.allowsUndo && !editor.isRichText)
    #expect(!editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled
            && !editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticSpellingCorrectionEnabled)
    for viaShortcut in [false, true] {
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        try h.key(" ", code: 49)
        try h.key("x", code: 7)
        #expect(editor.string == "Hello x", "typed before \(viaShortcut ? "Command-Z" : "Edit › 撤销")")
        editor.breakUndoCoalescing()
        #expect(try h.editMenuUndo(viaShortcut: viaShortcut) === editor, "the editor answers undo:")
        #expect(editor.string == "Hello", "\(viaShortcut ? "Command-Z" : "Edit › 撤销") restores the text")
    }
    let manager = try #require(editor.undoManager)
    try h.key("y", code: 16)
    #expect(manager.canUndo)
    try await h.reset(inspector: false)
    #expect(!manager.canUndo, "the editor's undo stack ends with the panel")
    #expect(h.window.undoManager?.canUndo != true, "nothing from the editor is left on the window's stack")
    #expect(try h.commandE())
    h.context.mark()
    #expect(try h.editMenuUndo(viaShortcut: true) === h.controller, "Annotate's undo: answers Command-Z")
    #expect(h.controller.session.annotateMode?.document.marks.isEmpty == true, "Annotate's Command-Z undoes the mark")
}

// MARK: - Matrix

private enum Fix5Focus: String, CaseIterable { case canvas, notice, editor }
private enum Fix5Exit: String, CaseIterable { case timer, escape, rerun, imageChange, commandE, viewAnnotate }

/// Inspector {shown, hidden} × focus {canvas, notice, editor} × exit {timer, Esc, re-run, image change, ⌘E, View › 标注}
/// × input {ABC, composing}, driven with `window.sendEvent`, menu validation and `NSApp.mainMenu.performKeyEquivalent`.
/// Pruned: timer × editor (an open panel has no timer); composing × {canvas, notice} (only the editor composes);
/// composing × {timer, re-run, image change} (no panel timer; the two menu items are not keys an input method holds);
/// Esc × {canvas, notice} (with no panel, Esc is the viewer's own return to the grid, not an OCR exit).
@MainActor @Test(.timeLimit(.minutes(6))) func issue687Fix5FocusExitInputMatrix() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    var rows = 0
    for visible in [true, false] {
        for focus in Fix5Focus.allCases {
            for exit in Fix5Exit.allCases {
                for composing in [false, true] {
                    if exit == .timer && focus == .editor { continue }
                    if exit == .escape && focus != .editor { continue }
                    if composing && (focus != .editor || exit == .rerun || exit == .imageChange || exit == .timer) { continue }
                    rows += 1
                    let label = "inspector=\(visible) focus=\(focus.rawValue) exit=\(exit.rawValue) composing=\(composing)"
                    try await h.reset(inspector: visible)
                    h.text = "Row \(rows)"
                    try await h.recognise()
                    #expect(h.overlay?.noticeView != nil, "\(label): notice shown")
                    var editor: RecogniseTextEditor?
                    switch focus {
                    case .canvas: break
                    case .notice: _ = try h.focusNotice()
                    case .editor: editor = try h.openEditor()
                    }
                    if composing, let editor { h.compose(editor) }

                    let urlBefore = h.controller.session.imageLoader.fileURL
                    switch exit {
                    case .timer: h.fireDismissals()
                    case .escape: try h.key("\u{1b}", code: 53)
                    case .rerun:
                        h.text = "Row \(rows) again"
                        try await h.recognise()
                    case .imageChange:
                        // The pod's ‹/› buttons (a click needs no keyboard focus; the bare-arrow menu items follow
                        // the Session's typing state).
                        #expect(h.controller.route(urlBefore?.lastPathComponent == h.context.first.lastPathComponent ? .next : .previous, from: .button),
                                "\(label): navigation available")
                        try await waitUntil("\(label): image changed", timeout: .seconds(60)) {
                            h.controller.session.imageLoader.fileURL != urlBefore && h.controller.session.imageStatus == .showing
                                && h.overlay?.noticeView == nil && h.overlay?.panelView == nil
                        }
                    case .commandE: _ = try h.commandE()
                    case .viewAnnotate:
                        if try h.context.enabled("annotate.enter.menu") { try h.context.perform("annotate.enter.menu") }
                    }

                    let panel = h.overlay?.panelView != nil, notice = h.overlay?.noticeView != nil
                    if composing, let editor {
                        #expect(panel && h.window.firstResponder === editor, "\(label): the composing editor keeps the keys")
                        #expect(!h.controller.session.isAnnotating, "\(label): no Annotate entry while composing")
                        if exit == .escape { #expect(!editor.hasMarkedText(), "\(label): Esc dropped the composition") }
                        continue
                    }
                    switch exit {
                    case .timer:
                        #expect(!notice && !panel, "\(label): notice timed out")
                    case .escape:
                        #expect(!panel, "\(label): no panel after Esc")
                    case .rerun:
                        #expect(notice && !panel, "\(label): the new run's notice")
                    case .imageChange:
                        #expect(!notice && !panel, "\(label): OCR cleared by the image change")
                    case .commandE, .viewAnnotate:
                        #expect(h.controller.session.isAnnotating, "\(label): Annotate Mode on")
                        #expect(!notice && !panel, "\(label): OCR closed first")
                    }
                    try h.expectCanvasOwnsKeys(label)
                }
            }
        }
    }
    #expect(rows == 36)
}

// MARK: - Review

/// Review M4: with the panel open, a composition in another text input (an Inspector field) owns Esc; the panel's
/// Esc must not close OCR or take the input method's key.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5ComposingOtherTextInputKeepsEscWithPanelOpen() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    try await h.reset(inspector: true)
    try await h.recognise()
    _ = try h.openEditor()
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
    h.window.contentView?.addSubview(other)
    defer { other.removeFromSuperview() }
    #expect(h.window.makeFirstResponder(other))
    h.compose(other)
    #expect(other.hasMarkedText())
    try h.key("\u{1b}", code: 53)
    #expect(h.overlay?.panelView != nil, "Esc during another input's composition leaves the OCR panel open")
    #expect(h.window.firstResponder === other, "the composing input keeps focus")
}

/// Review M2/5: removals while the Inspector holds focus leave it there, and Tab from the Inspector close control
/// with the panel open goes to the canvas.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5PanelRemovalLeavesInspectorFocusAlone() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    func toInspector() async throws {
        try await h.reset(inspector: true)
        try await h.recognise()
        _ = try h.openEditor()
        for _ in 0..<3 { try h.key("\t", code: 48) }
        #expect((h.window.firstResponder as? NSView)?.accessibilityIdentifier() == "inspector.close")
    }
    try await toInspector()
    try h.key("\t", code: 48)
    try h.expectCanvasOwnsKeys("Tab from the Inspector close control with the panel open")
    #expect(h.overlay?.panelView != nil)

    try await toInspector()
    h.text = "Again"
    try await h.recognise()
    #expect(h.overlay?.panelView == nil)
    #expect((h.window.firstResponder as? NSView)?.accessibilityIdentifier() == "inspector.close",
            "a new run does not take focus from the Inspector")

    try await toInspector()
    let before = h.controller.session.imageLoader.fileURL
    #expect(h.controller.route(before?.lastPathComponent == h.context.first.lastPathComponent ? .next : .previous,
                               from: .button))
    try await waitUntil("the other image is shown", timeout: .seconds(60)) {
        h.controller.session.imageLoader.fileURL != before && h.controller.session.imageStatus == .showing && h.editor == nil
    }
    #expect((h.window.firstResponder as? NSView)?.accessibilityIdentifier() == "inspector.close",
            "an image change does not take focus from the Inspector")
}

/// Review L6/L7: Edit › 撤销 validates against the editor's own stack through the menu-item path, and that stack is
/// not the window's.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5EditorUndoMenuFollowsTheEditorStack() async throws {
    let h = try await Fix5Harness()
    defer { h.close() }
    try await h.reset(inspector: false)
    try await h.recognise()
    let editor = try h.openEditor()
    let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
    #expect(!editor.validateMenuItem(item), "nothing typed: Undo is disabled")
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    try h.key("x", code: 7)
    #expect(editor.validateMenuItem(item), "after typing: Undo is enabled")
    #expect(editor.undoManager !== h.window.undoManager, "the editor's stack is its own")
}
