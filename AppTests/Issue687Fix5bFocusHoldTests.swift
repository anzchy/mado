import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5b F9 (owner 2026-11-15: 「有焦点时不消失（推荐）」): like hover, keyboard or VoiceOver focus on the notice
// holds it; once focus leaves, the 5 s count starts again. Each finished recognition is announced to VoiceOver.

/// Keyboard focus: the clock passes 5 s and the notice stays focused; Tab moves focus on, the count restarts, and the
/// notice goes 5 s later without taking focus from where it went.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bKeyboardFocusHoldsTheNotice() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    for visible in [false, true] {
        try await h.reset(inspector: visible)
        let label = "Inspector visible=\(visible)"
        try await h.recognise()
        let notice = try #require(h.overlay?.noticeView)
        _ = h.window.makeFirstResponder(notice)
        #expect(h.window.firstResponder === notice)
        h.fireDismissals()
        #expect(h.overlay?.noticeView === notice, "\(label): a focused notice outlives 5 s")
        #expect(h.window.firstResponder === notice, "\(label): and keeps focus")
        #expect(h.pendingDismissals.isEmpty, "\(label): no count runs while it is focused")

        try h.key("\t", code: 48)
        let moved = h.window.firstResponder
        #expect(moved !== notice, "\(label): Tab moved focus on")
        #expect(h.pendingDismissals.count == 1, "\(label): leaving restarts the 5 s count")
        h.fireDismissals()
        #expect(h.overlay?.noticeView == nil, "\(label): the notice goes 5 s after focus left")
        #expect(h.window.firstResponder === moved, "\(label): focus stays where Tab put it")
    }
}

/// VoiceOver focus holds the warning notice too (it is not a keyboard stop); losing it restarts the count.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bVoiceOverFocusHoldsTheNotice() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    try await h.reset(inspector: false)
    h.text = ""
    try await h.recognise()
    let warning = try #require(h.overlay?.noticeView)
    #expect(warning.kind == .warning)
    warning.setAccessibilityFocused(true)
    h.fireDismissals()
    #expect(h.overlay?.noticeView === warning, "a VoiceOver-focused notice outlives 5 s")
    #expect(h.window.firstResponder === h.controller.canvas, "the warning never takes keyboard focus")
    warning.setAccessibilityFocused(false)
    #expect(h.pendingDismissals.count == 1, "losing VoiceOver focus restarts the 5 s count")
    h.fireDismissals()
    #expect(h.overlay?.noticeView == nil)
    #expect(h.window.firstResponder === h.controller.canvas)

    // The success notice: VoiceOver focus also moves keyboard focus (round 4); either one holds it.
    h.text = "Hello"
    try await h.recognise()
    let success = try #require(h.overlay?.noticeView)
    success.setAccessibilityFocused(true)
    #expect(h.window.firstResponder === success)
    h.fireDismissals()
    #expect(h.overlay?.noticeView === success, "a VoiceOver-focused success notice outlives 5 s")
}

/// One announcement per finished recognition, with the notice's own label, for success and no text.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bEachRecognitionIsAnnouncedOnce() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    try await h.reset(inspector: false)
    try await h.recognise()
    let success = try #require(h.overlay?.noticeView?.accessibilityLabel())
    #expect(h.announcements == [success])
    h.text = ""
    try await h.recognise()
    let noText = try #require(h.overlay?.noticeView?.accessibilityLabel())
    #expect(h.announcements == [success, noText])
    // Opening and closing the panel is not a new result.
    h.text = "Again"
    try await h.recognise()
    let notice = try #require(h.overlay?.noticeView)
    _ = h.window.makeFirstResponder(notice)
    try h.key(" ", code: 49)
    #expect(h.controller.recogniseTextAdapter.panelEditor != nil)
    try h.key("\u{1b}", code: 53)
    #expect(h.announcements.count == 3)
}
