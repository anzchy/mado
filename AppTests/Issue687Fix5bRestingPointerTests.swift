import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5b F12 (amendment 4): a notice that appears under a resting pointer counts as hovered, so it does not
// vanish under the pointer; the pointer leaving (the tracking area's exit) restarts the 5 s count.

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bNoticeUnderARestingPointerIsHovered() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    try await h.reset(inspector: false)
    // The pointer rests where the notice will appear: the centre of its frame once laid out.
    h.controller.recogniseTextAdapter.pointerLocation = { [weak h] in
        guard let notice = h?.overlay?.noticeView, notice.frame.width > 0 else { return nil }
        return notice.convert(NSPoint(x: notice.bounds.midX, y: notice.bounds.midY), to: nil)
    }
    try await h.recognise()
    let notice = try #require(h.overlay?.noticeView)
    h.fireDismissals()
    #expect(h.overlay?.noticeView === notice, "a notice under the resting pointer outlives 5 s")
    let area = try #require(notice.trackingAreas.first)
    #expect(area.options.contains(.assumeInside), "the tracking area starts inside, so leaving sends an exit")
    let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
        trackingNumber: 0, userData: nil))
    notice.mouseExited(with: exit)
    #expect(h.pendingDismissals.count == 1, "leaving restarts the 5 s count")
    h.fireDismissals()
    #expect(h.overlay?.noticeView == nil)

    // Control: a pointer elsewhere does not hold the notice.
    h.controller.recogniseTextAdapter.pointerLocation = { NSPoint(x: 1, y: 1) }
    try await h.recognise()
    h.fireDismissals()
    #expect(h.overlay?.noticeView == nil, "a notice away from the pointer goes after 5 s")
}
