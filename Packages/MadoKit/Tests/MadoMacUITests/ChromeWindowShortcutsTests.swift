import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@MainActor private final class ChromeCloseProbe: NSObject, NSWindowDelegate {
    var requests = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeWindowCloseShortcutWorksWithHiddenAndVisibleControls() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 680),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let probe = ChromeCloseProbe(); window.delegate = probe
    let overlay = ViewerChromeOverlay(frame: window.contentView!.bounds, session: ViewerSession())
    window.contentView!.addSubview(overlay)
    defer { window.close(); withExtendedLifetime(probe) {} }
    let file = NSMenu(title: "File"); file.autoenablesItems = false
    let closeItem = ChromeWindowCommands.addClose(to: file)
    #expect(closeItem.title == "Close")
    #expect(closeItem.action == #selector(NSWindow.performClose(_:)))
    #expect(closeItem.keyEquivalent == "w")
    #expect(closeItem.keyEquivalentModifierMask == [.command])
    #expect(closeItem.target == nil)
    // The real App responder chain is a device check; explicitly target this offscreen window.
    closeItem.target = window
    let close = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
        isARepeat: false, keyCode: 13))
    for visible in [false, true] {
        overlay.setToolsVisible(visible)
        #expect(file.performKeyEquivalent(with: close))
    }
    #expect(probe.requests == 2)
    let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "W", charactersIgnoringModifiers: "w",
        isARepeat: false, keyCode: 13))
    #expect(!file.performKeyEquivalent(with: other))
    #expect(!overlay.performKeyEquivalent(with: close))
    #expect(probe.requests == 2)
}
