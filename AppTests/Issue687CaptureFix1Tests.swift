import AppKit
import Testing
import MadoApplication

// #687c fix round 1: a Capture or selection that starts while a 截图并识别文字 read is pending makes that read stale
// (F1); the helper panel's editor answers the Edit key equivalents without an Edit menu (M1).
// Every wait here ends within `fix1Limit`: a stub that never answers fails, it never hangs.

private let fix1Limit = Duration.seconds(5)
private struct Fix1ReadFailed: Error {}

/// Counts recognitions and answers each with the PNG's own text.
private final class Fix1Recognitions: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Data] = []
    var count: Int { lock.withLock { calls.count } }
    var recognise: CaptureRecogniseTextPresenter.Recognise {
        { [self] png in
            lock.withLock { calls.append(png) }
            let text = String(decoding: png, as: UTF8.self)
            return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: false)
        }
    }
}

/// A screen read the test releases; unreleased, it fails after `fix1Limit`.
@MainActor private final class Fix1Read {
    let png: Data
    var started = false
    var released = false
    var failure: Error?
    init(_ text: String) { png = Data(text.utf8) }
    func read() async throws -> (png: Data, visibleFrame: NSRect) {
        started = true
        let deadline = ContinuousClock.now + fix1Limit
        while !released {
            guard ContinuousClock.now < deadline else { throw Fix1ReadFailed() }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let failure { throw failure }
        return (png, NSRect(x: 0, y: 25, width: 1440, height: 875))
    }
}

/// One `recognise` call's outcome, filled in when it returns.
@MainActor private final class Fix1Call {
    var finished = false
    var presented: Task<Void, Never>?
    var error: Error?
    var willPresentCount = 0
}

@MainActor private final class Fix1Harness {
    let recognitions = Fix1Recognitions()
    let pasteboard = NSPasteboard(name: .init("mado.test.687c.fix1.\(UUID().uuidString)"))
    let presenter: CaptureRecogniseTextPresenter

    init() {
        _ = NSApplication.shared
        presenter = CaptureRecogniseTextPresenter(recognise: recognitions.recognise,
                                                  pasteboard: NativeTextPasteboard(pasteboard),
                                                  scheduleDismiss: { _, _ in }, scheduleConfirmationReset: { _ in },
                                                  announce: { _ in })
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
    }
    func close() { presenter.dismiss(); presenter.panel.orderOut(nil); pasteboard.releaseGlobally() }

    /// Starts 截图并识别文字 on `read` under `ticket` (by default one taken now, as a selection's completion does);
    /// the call's outcome lands in the returned record.
    func start(_ read: Fix1Read, ticket: CaptureRecogniseTextPresenter.Ticket? = nil) -> Fix1Call {
        let call = Fix1Call()
        let ticket = ticket ?? presenter.ticket()
        Task { @MainActor in
            do {
                call.presented = try await presenter.recognise(ticket: ticket, read: { try await read.read() },
                                                               willPresent: { call.willPresentCount += 1 })
            } catch { call.error = error }
            call.finished = true
        }
        return call
    }
    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + fix1Limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    /// The presented recognition, awaited at most `fix1Limit`.
    func finish(_ task: Task<Void, Never>?) async -> Bool {
        guard let task else { return false }
        var done = false
        Task { await task.value; done = true }
        return await eventually { done }
    }
}

// MARK: - F1

/// A read pending when another Capture or selection starts (which dismisses the presenter) shows nothing and leaves
/// the clipboard alone when it resumes.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1DismissDuringReadPresentsNothing() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let changeCount = h.pasteboard.changeCount
    let a = Fix1Read("text A")
    let call = h.start(a)
    #expect(await h.eventually { a.started }, "A's screen read is pending")
    h.presenter.dismiss()  // B starts: CaptureHelperMain's capture() / startSelection
    a.released = true
    #expect(await h.eventually { call.finished }, "A resumes and returns")
    #expect(call.presented == nil, "A presents nothing")
    #expect(call.willPresentCount == 0, "A does not touch the status panel either")
    #expect(call.error == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(h.recognitions.count == 0, "A's image is never recognised")
    #expect(!h.presenter.panel.isVisible)
    #expect(h.presenter.overlay.noticeView == nil && h.presenter.overlay.panelView == nil)
    #expect(h.pasteboard.changeCount == changeCount, "the clipboard is untouched")
    #expect(h.pasteboard.string(forType: .string) == "before")
}

/// B's result stays when A's stale read resumes after B presented.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1LaterRecogniseKeepsItsResult() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let a = Fix1Read("text A")
    let callA = h.start(a)
    #expect(await h.eventually { a.started })
    h.presenter.dismiss()  // B's selection starts
    let b = Fix1Read("text B")
    b.released = true
    let callB = h.start(b)
    #expect(await h.eventually { callB.finished })
    #expect(await h.finish(callB.presented), "B presents")
    #expect(h.pasteboard.string(forType: .string) == "text B")
    let afterB = h.pasteboard.changeCount
    a.released = true
    #expect(await h.eventually { callA.finished })
    #expect(callA.presented == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(h.recognitions.count == 1, "only B's image is recognised")
    #expect(h.pasteboard.changeCount == afterB && h.pasteboard.string(forType: .string) == "text B")
    #expect(h.presenter.overlay.noticeView != nil, "B's notice stays")
}

/// A stale read's failure is dropped (the newer operation reports its own); a current failure still throws.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1StaleReadFailureIsDropped() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let stale = Fix1Read("stale")
    stale.failure = Fix1ReadFailed()
    let staleCall = h.start(stale)
    #expect(await h.eventually { stale.started })
    h.presenter.dismiss()
    stale.released = true
    #expect(await h.eventually { staleCall.finished })
    #expect(staleCall.error == nil, "a stale failure is not reported")
    #expect(staleCall.presented == nil)
    let current = Fix1Read("current")
    current.failure = Fix1ReadFailed()
    current.released = true
    let currentCall = h.start(current)
    #expect(await h.eventually { currentCall.finished })
    #expect(currentCall.error is Fix1ReadFailed, "a current failure is reported")
    #expect(currentCall.willPresentCount == 0)
}

/// With nothing in between, a read presents: the status panel is hidden first and the text is copied.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1CurrentReadPresents() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let a = Fix1Read("current text")
    a.released = true
    let call = h.start(a)
    #expect(await h.eventually { call.finished })
    #expect(call.willPresentCount == 1)
    #expect(await h.finish(call.presented))
    #expect(h.recognitions.count == 1)
    #expect(h.pasteboard.string(forType: .string) == "current text")
    #expect(h.presenter.overlay.noticeView != nil)
}

// MARK: - Fix round 2 F1b

/// A selection's ticket is taken when it completes; a Capture or another selection that dismisses the presenter
/// before A's Task reaches the presenter makes A stale: A's read never starts, nothing shows, nothing is copied.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix2DismissBeforeStartPresentsNothing() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let changeCount = h.pasteboard.changeCount
    let ticketA = h.presenter.ticket()  // A's selection completes and enqueues its Task
    h.presenter.dismiss()  // B's Capture or selection starts before A's Task runs
    let a = Fix1Read("text A")
    a.released = true
    let call = h.start(a, ticket: ticketA)
    #expect(await h.eventually { call.finished }, "A's Task returns")
    #expect(!a.started, "A's screen read never starts")
    #expect(call.presented == nil, "A presents nothing")
    #expect(call.willPresentCount == 0)
    #expect(call.error == nil, "nothing to report")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(h.recognitions.count == 0, "A's image is never recognised")
    #expect(!h.presenter.panel.isVisible)
    #expect(h.presenter.overlay.noticeView == nil && h.presenter.overlay.panelView == nil)
    #expect(h.pasteboard.changeCount == changeCount, "the clipboard is untouched")
}

/// B, selected after A's dismissal, presents; A's Task running later does not replace or copy over B.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix2LateStartKeepsTheNewerResult() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let ticketA = h.presenter.ticket()
    h.presenter.dismiss()  // B's selection starts
    let b = Fix1Read("text B")
    b.released = true
    let callB = h.start(b)
    #expect(await h.eventually { callB.finished })
    #expect(await h.finish(callB.presented), "B presents")
    let afterB = h.pasteboard.changeCount
    let a = Fix1Read("text A")
    a.released = true
    let callA = h.start(a, ticket: ticketA)
    #expect(await h.eventually { callA.finished })
    #expect(!a.started && callA.presented == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(h.recognitions.count == 1, "only B's image is recognised")
    #expect(h.pasteboard.changeCount == afterB && h.pasteboard.string(forType: .string) == "text B")
    #expect(h.presenter.overlay.noticeView != nil, "B's notice stays")
}

/// Quitting (applicationWillTerminate dismisses) before A's Task runs: A's read never starts, so its failure is
/// never reported either.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix2QuitBeforeStartReportsNothing() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let changeCount = h.pasteboard.changeCount
    let ticketA = h.presenter.ticket()
    h.presenter.dismiss()  // the helper quits
    let a = Fix1Read("text A")
    a.failure = Fix1ReadFailed()
    a.released = true
    let call = h.start(a, ticket: ticketA)
    #expect(await h.eventually { call.finished })
    #expect(!a.started, "A's screen read never starts")
    #expect(call.error == nil, "no failure is reported")
    #expect(call.presented == nil && call.willPresentCount == 0)
    #expect(h.recognitions.count == 0)
    #expect(h.pasteboard.changeCount == changeCount)
}

// MARK: - M1

@MainActor private func fix1Key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                                window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                  context: nil, characters: characters,
                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}

/// Recognises `text` and opens the editable panel with a click on the notice; returns the editor.
@MainActor private func fix1OpenEditor(_ h: Fix1Harness, text: String) async throws -> NSTextView {
    let read = Fix1Read(text)
    read.released = true
    let call = h.start(read)
    try #require(await h.eventually { call.finished })
    try #require(await h.finish(call.presented))
    let notice = try #require(h.presenter.overlay.noticeView)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.presenter.panel.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    notice.mouseDown(with: down)
    let editor = try #require(h.presenter.overlay.panelView?.textView)
    try #require(h.presenter.panel.firstResponder === editor)
    return editor
}

/// Law: exactly ⌘A/⌘C/⌘X/⌘V/⌘Z/⇧⌘Z map to the Edit actions; other keys and modifiers map to nothing.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1EditKeyEquivalentsMap() throws {
    let window = NSWindow()
    let expected: [(String, UInt16, NSEvent.ModifierFlags, String?)] = [
        ("a", 0, .command, "selectAll:"), ("c", 8, .command, "copy:"), ("x", 7, .command, "cut:"),
        ("v", 9, .command, "paste:"), ("z", 6, .command, "undo:"), ("Z", 6, [.command, .shift], "redo:"),
        ("z", 6, [.command, .shift], "redo:"),
        ("a", 0, [], nil), ("z", 6, [], nil), ("a", 0, [.command, .option], nil), ("c", 8, [.command, .control], nil),
        ("a", 0, [.command, .shift], nil), ("q", 12, .command, nil), ("w", 13, .command, nil)
    ]
    for (characters, code, modifiers, action) in expected {
        let event = try fix1Key(characters, code: code, modifiers: modifiers, window: window)
        #expect(CaptureRecogniseTextPanel.editAction(for: event).map(NSStringFromSelector) == action,
                "\(modifiers.rawValue) \(characters)")
    }
    let keyUp = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
        isARepeat: false, keyCode: 0))
    #expect(CaptureRecogniseTextPanel.editAction(for: keyUp) == nil)
}

/// ⌘A selects all of the editor's text and ⌘Z / ⇧⌘Z undo and redo typing, from real key events on the panel.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1PanelEditorAnswersSelectAllAndUndo() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let editor = try await fix1OpenEditor(h, text: "Hello")
    let panel = h.presenter.panel
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(panel.performKeyEquivalent(with: try fix1Key("a", code: 0, modifiers: .command, window: panel)))
    #expect(editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length))
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    editor.keyDown(with: try fix1Key("x", code: 7, window: panel))
    #expect(editor.string == "Hellox")
    editor.breakUndoCoalescing()
    #expect(panel.performKeyEquivalent(with: try fix1Key("z", code: 6, modifiers: .command, window: panel)))
    #expect(editor.string == "Hello", "⌘Z undoes the typing")
    #expect(panel.performKeyEquivalent(with: try fix1Key("Z", code: 6, modifiers: [.command, .shift], window: panel)))
    #expect(editor.string == "Hellox", "⇧⌘Z redoes it")
    #expect(!panel.performKeyEquivalent(with: try fix1Key("q", code: 12, modifiers: .command, window: panel)),
            "other key equivalents pass through")
}

/// With nothing to undo, ⌘Z is not consumed and changes nothing; with only the notice up, ⌘A does nothing.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFix1EditKeysNeedAnAnsweringEditor() async throws {
    let h = Fix1Harness()
    defer { h.close() }
    let read = Fix1Read("notice only")
    read.released = true
    let call = h.start(read)
    #expect(await h.eventually { call.finished })
    #expect(await h.finish(call.presented))
    let panel = h.presenter.panel
    #expect(h.presenter.overlay.noticeView != nil)
    #expect(!panel.performKeyEquivalent(with: try fix1Key("a", code: 0, modifiers: .command, window: panel)))
    h.presenter.dismiss()
    let editor = try await fix1OpenEditor(h, text: "Fresh")
    #expect(editor.undoManager?.canUndo != true)
    #expect(!panel.performKeyEquivalent(with: try fix1Key("z", code: 6, modifiers: .command, window: panel)))
    #expect(editor.string == "Fresh")
}
