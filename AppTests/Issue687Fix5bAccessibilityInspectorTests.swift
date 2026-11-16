import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5b F14 (amendment 4): with the panel open, an accessibility focus move (VoiceOver, AXFocused) to an
// Inspector control is let through; only the automatic replay during opening stays blocked.

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bAccessibilityFocusReachesTheInspectorWithThePanelOpen() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    try await h.reset(inspector: true)
    try await h.recognise()
    let panel = try h.openPanel()
    #expect(h.window.firstResponder === panel.textView, "the opening left the editor focused")
    let close = try #require(h.inspectorClose)
    // Control: a plain programmatic move (the replay's path) is still refused while the panel is open.
    _ = h.window.makeFirstResponder(close)
    #expect(h.window.firstResponder === panel.textView, "the automatic replay stays blocked")
    close.setAccessibilityFocused(true)
    #expect(h.window.firstResponder === close, "AXFocused moved focus into the Inspector")
    #expect(h.overlay?.panelView === panel, "the panel stays open")
    #expect(h.controller.session.inspectorFocus.focus == .panel)
}
