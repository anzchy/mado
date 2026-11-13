import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func statesLoadingHasFilenameIndeterminateProgressAndCancelOnly() throws {
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
    state.display(.loading("A.png"))
    #expect(state.showsProgress)
    #expect(state.textLines == ["Opening A.png…"])
    #expect(state.buttons.count == 1)
    let cancel = try #require(state.buttons.first)
    #expect(cancel.title == "Cancel")
    #expect(cancel.accessibilityIdentifier() == "state.cancel")
    let generation = session.imageLoader.generation
    cancel.performClick(nil)
    state.refresh()
    #expect(session.imageStatus == .empty)
    #expect(session.imageLoader.generation != generation)
    #expect(!state.showsProgress)
    #expect(state.buttons.first?.accessibilityIdentifier() == "state.open")
    state.display(.loading("名称.png"))
    #expect(state.textLines == ["Opening 名称.png…"])
    #expect(state.showsProgress)
    state.display(.showing)
    #expect(!state.showsProgress)
    #expect(state.textLines.isEmpty)
    #expect(state.buttons.isEmpty)
}
