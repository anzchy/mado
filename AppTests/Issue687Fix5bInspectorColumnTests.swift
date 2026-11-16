import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r5b F10 (amendment 4, owner 2026-11-15: 「剩下几项也放进第 5 轮一起修」): with the Inspector shown the
// notice and the panel keep 20 pt from the canvas's right edge, left of the Inspector column; hidden, from the
// window's. Their bottom edge stays above the zoom group (F8).

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bNoticeAndPanelStayLeftOfTheInspector() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    let screen = h.window.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    for size in [NSSize(width: 900, height: 600), screen] {
        h.window.setContentSize(size)
        for visible in [true, false] {
            try await h.reset(inspector: visible)
            let label = "\(Int(size.width))×\(Int(size.height)), Inspector visible=\(visible)"
            try await h.recognise()
            let overlay = try #require(h.overlay)
            let column = h.inspectorColumn
            #expect((column != nil) == visible, "\(label): the Inspector column is \(visible ? "shown" : "hidden")")
            let trailing = column?.minX ?? h.windowFrame(overlay).maxX
            for (name, view) in [("notice", overlay.noticeView as NSView?), ("panel", nil)] {
                let surface: NSView = name == "notice" ? try #require(view) : try h.openPanel()
                let frame = h.windowFrame(surface)
                #expect(trailing - frame.maxX == 20, "\(label): \(name) 20 pt from the \(visible ? "Inspector" : "window") edge")
                if let column { #expect(!frame.intersects(column), "\(label): \(name) \(frame) clear of the Inspector \(column)") }
                #expect(!frame.intersects(h.windowFrame(h.zoomPod)), "\(label): \(name) clear of the zoom group")
            }
        }
    }
}

/// Showing or hiding the Inspector while the notice or the panel is up moves them with the edge.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bInspectorToggleMovesTheNoticeAndPanel() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    h.window.setContentSize(NSSize(width: 900, height: 600))
    try await h.reset(inspector: false)
    try await h.recognise()
    let overlay = try #require(h.overlay)
    for surface in ["notice", "panel"] {
        if surface == "panel" { _ = try h.openPanel() }
        func view() throws -> NSView { try #require(surface == "notice" ? overlay.noticeView : overlay.panelView) }
        let hiddenMaxX = h.windowFrame(try view()).maxX
        h.controller.session.setInspectorVisible(true)
        h.controller.showInspector(true)
        h.window.contentView?.layoutSubtreeIfNeeded()
        let column = try #require(h.inspectorColumn)
        #expect(column.minX - h.windowFrame(try view()).maxX == 20, "\(surface) moved left of the shown Inspector")
        h.controller.session.setInspectorVisible(false)
        h.controller.showInspector(false)
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(h.windowFrame(try view()).maxX == hiddenMaxX, "\(surface) back at the window edge")
    }
}
