import AppKit
import SwiftUI
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #687 fix r5b F14: an accessibility focus request on the Inspector's close control moves keyboard focus there and
// marks the move as accessibility-initiated for the window's responder policy, only for its duration.

private struct Fix5bInspectorReader: InspectorMetadataReading {
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata { .init() }
}

private final class Fix5bRecordingWindow: NSWindow {
    var marks: [Bool] = []
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        MainActor.assumeIsolated { marks.append(InspectorAccessibilityFocus.isMoving) }
        return super.makeFirstResponder(responder)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue687Fix5bInspectorCloseTakesAccessibilityFocus() throws {
    _ = NSApplication.shared
    let session = ViewerSession()
    let window = Fix5bRecordingWindow(contentRect: NSRect(x: -20000, y: -20000, width: 220, height: 500),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let panel = NSHostingView(rootView: InspectorPanel(model: InspectorModel(reader: Fix5bInspectorReader()),
        session: session, close: {}, restoreCanvasFocus: {}, updateFocus: { session.updateFocus($0) }))
    panel.frame = NSRect(x: 0, y: 0, width: 220, height: 500)
    window.contentView = panel
    session.setInspectorVisible(true)
    panel.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let close = try #require(descendants(panel).compactMap { $0 as? NSButton }
        .first { $0.accessibilityIdentifier() == "inspector.close" })
    window.marks = []
    close.setAccessibilityFocused(true)
    #expect(window.firstResponder === close)
    #expect(window.marks.first == true, "the move is marked as accessibility-initiated while it runs")
    #expect(!InspectorAccessibilityFocus.isMoving, "and only then")
    window.marks = []
    close.setAccessibilityFocused(false)
    #expect(window.marks.allSatisfy { !$0 }, "losing accessibility focus is not a focus move")
}
