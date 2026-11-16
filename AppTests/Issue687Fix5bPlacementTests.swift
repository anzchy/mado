import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5b F8 (owner 2026-11-15: 「移到缩放组上方（推荐）」): the notice and the panel stay bottom-right, 20 pt
// from the right edge, with their bottom edge above the zoom group, so they cover no viewer control.

/// For the Inspector shown and hidden, a default window and a screen-sized one (full-screen geometry): the notice and
/// the panel intersect no chrome pod, sit 8 pt above the zoom group, and (Inspector hidden) keep 20 pt from the right.
/// With the Inspector shown the right edge is F10's (`Issue687Fix5bInspectorColumnTests`).
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bNoticeAndPanelSitAboveTheZoomGroup() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    let screen = h.window.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    for size in [NSSize(width: 900, height: 600), screen] {
        h.window.setContentSize(size)
        for visible in [true, false] {
            try await h.reset(inspector: visible)
            h.chrome.layoutSubtreeIfNeeded()
            let label = "\(Int(size.width))×\(Int(size.height)), Inspector visible=\(visible)"
            try await h.recognise()
            let overlay = try #require(h.overlay)
            let notice = try #require(overlay.noticeView)
            let noticeFrame = h.windowFrame(notice)
            if !visible { #expect(overlay.bounds.maxX - notice.frame.maxX == 20, "\(label): notice 20 pt from the right") }
            for pod in h.podFrames {
                #expect(!noticeFrame.intersects(pod), "\(label): notice \(noticeFrame) clear of pod \(pod)")
            }
            let zoomTop = h.windowFrame(h.zoomPod).maxY
            #expect(noticeFrame.minY == zoomTop + 8, "\(label): notice 8 pt above the zoom group")
            _ = h.window.makeFirstResponder(notice)
            try h.key(" ", code: 49)
            overlay.layoutSubtreeIfNeeded()
            let panel = try #require(overlay.panelView)
            let panelFrame = h.windowFrame(panel)
            if !visible { #expect(overlay.bounds.maxX - panel.frame.maxX == 20, "\(label): panel 20 pt from the right") }
            for pod in h.podFrames {
                #expect(!panelFrame.intersects(pod), "\(label): panel \(panelFrame) clear of pod \(pod)")
            }
            #expect(panelFrame.maxY <= overlay.bounds.maxY - 20, "\(label): the panel stays inside the window")
        }
    }
}

/// The click that used to land on the notice capsule over 放大 now reaches the zoom button.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bZoomClickWhileTheNoticeShowsZooms() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    h.window.setContentSize(NSSize(width: 900, height: 600))
    try await h.reset(inspector: false)
    try await h.recognise()
    #expect(h.overlay?.noticeView != nil)
    let zoomIn = try #require(h.chrome.tools.first { $0.accessibilityIdentifier() == "command.\(CommandID.zoomIn.rawValue).button" })
    if zoomIn.isHiddenOrHasHiddenAncestor { h.controller.session.setChromeInteraction(.pointerHover, active: true) }
    try #require(!zoomIn.isHiddenOrHasHiddenAncestor, "the zoom group is shown")
    let point = zoomIn.convert(NSPoint(x: zoomIn.bounds.midX, y: zoomIn.bounds.midY), to: nil)
    let hit = h.window.contentView?.superview?.hitTest(point) ?? h.window.contentView?.hitTest(point)
    #expect(hit === zoomIn, "the zoom button is the click target, not \(String(describing: hit))")
    let before = h.controller.session.zoomMode
    // The press goes to the view the window's hit test picked: synthetic window events do not reach chrome tools
    // in this lane (a click with no notice at all leaves the zoom unchanged), so the hit test carries the proof.
    let target = try #require(hit)
    try h.press(target, at: point)
    // Bounded: before the fix the click opens the panel instead and the zoom never changes.
    for _ in 0..<100 where h.controller.session.zoomMode == before { try await Task.sleep(for: .milliseconds(10)) }
    #expect(h.controller.session.zoomMode != before, "放大 zoomed")
    #expect(h.controller.recogniseTextAdapter.panelEditor == nil, "the click did not open the panel")
}
