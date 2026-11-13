import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func statesEmptyContentRoutesOpenAndIgnoresUnrelatedRecents() throws {
    _ = NSApplication.shared
    let host = ChromeToolsHost()
    host.hasImage = false; host.canNavigate = false
    let session = ViewerSession(host: host)
    let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: frame)
    let canvas = CanvasView(frame: frame, session: session)
    let state = ViewerStateHost(frame: frame, session: session)
    content.addSubview(canvas); content.addSubview(state); window.contentView = content
    defer { window.close() }
    let existing = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/Existing"), displayName: "Existing Folder")
    for _ in [[], [existing]] {
        state.refresh()
        #expect(state.textLines == ["Drop a photo folder here", "or press ⌘O"])
        #expect(state.buttons.count == 1)
        let button = try #require(state.buttons.first)
        #expect(button.title == "Choose Folder…")
        #expect(button.accessibilityIdentifier() == "state.open")
        #expect(session.imageStatus == .empty)
    }
    let button = try #require(state.buttons.first)
    button.performClick(nil)
    #expect(host.opened == 1)
    #expect(host.entries.isEmpty)
    #expect(host.navigation.isEmpty)
    #expect(session.imageStatus == .empty)
    #expect(!canvas.hasImage)
}
