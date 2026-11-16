import AppKit
import Testing
import MadoCore
import MadoApplication

// #687 fix r6 (gpt M1 on F10): in a window that leaves 200–259 pt left of the Inspector column, the panel narrows to
// that space (floor 200 pt) and the notice stays left of the column; neither covers the column or the zoom group.
// Under the floor both keep the window edge (documented in ledger EXT-01 限制).

/// The Inspector column is 220 pt and overlays the content at ≤ 720 pt, so a content width W leaves W − 260 pt.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix6PanelNarrowsLeftOfTheInspectorDownToTheFloor() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    for remaining: CGFloat in [200, 230, 259] {
        h.window.setContentSize(NSSize(width: remaining + 260, height: 600))
        try await h.reset(inspector: true)
        let content = try #require(h.window.contentView)
        try #require(abs(content.bounds.width - (remaining + 260)) < 1, "the window takes width \(remaining + 260)")
        content.layoutSubtreeIfNeeded()
        let column = try #require(h.inspectorColumn, "the Inspector column is shown")
        let space = column.minX - 40
        let label = "\(Int(content.bounds.width)) pt window, \(Int(space)) pt left of the Inspector"
        try #require(space == remaining, "\(label): exactly \(remaining) pt left of the Inspector")
        try await h.recognise()
        let overlay = try #require(h.overlay)
        let zoom = h.windowFrame(h.zoomPod)
        let notice = h.windowFrame(try #require(overlay.noticeView))
        #expect(column.minX - notice.maxX == 20, "\(label): notice \(notice) 20 pt left of the Inspector \(column)")
        #expect(!notice.intersects(column), "\(label): notice clear of the Inspector")
        #expect(!notice.intersects(zoom), "\(label): notice clear of the zoom group")
        let panelView = try h.openPanel()
        let panel = h.windowFrame(panelView)
        #expect(column.minX - panel.maxX == 20, "\(label): panel \(panel) 20 pt left of the Inspector \(column)")
        #expect(panel.width == space, "\(label): the panel narrows to the \(space) pt left")
        #expect(!panel.intersects(column), "\(label): panel clear of the Inspector")
        #expect(!panel.intersects(zoom), "\(label): panel clear of the zoom group")
        for id in ["recognise-text.copy", "recognise-text.close"] {
            let control = panelView.subviews.first { $0.accessibilityIdentifier() == id }
            #expect(control.map { panelView.bounds.contains($0.frame) } == true, "\(label): \(id) inside the panel")
        }
    }
}

/// Under the floor, and with the Inspector hidden, both surfaces keep 20 pt from the window edge.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix6UnderTheFloorKeepsTheWindowEdge() async throws {
    let h = try await Fix5bHarness()
    defer { h.close() }
    for (width, visible) in [(CGFloat(440), true), (460, false), (519, false)] {
        h.window.setContentSize(NSSize(width: width, height: 600))
        try await h.reset(inspector: visible)
        let content = try #require(h.window.contentView)
        try #require(abs(content.bounds.width - width) < 1, "the window takes width \(width)")
        content.layoutSubtreeIfNeeded()
        let label = "\(Int(width)) pt window, Inspector visible=\(visible)"
        #expect((h.inspectorColumn != nil) == visible, "\(label): Inspector column")
        try await h.recognise()
        let overlay = try #require(h.overlay)
        let edge = h.windowFrame(overlay).maxX
        let notice = h.windowFrame(try #require(overlay.noticeView))
        #expect(edge - notice.maxX == 20, "\(label): notice 20 pt from the window edge")
        let panel = h.windowFrame(try h.openPanel())
        #expect(edge - panel.maxX == 20, "\(label): panel 20 pt from the window edge")
    }
}
