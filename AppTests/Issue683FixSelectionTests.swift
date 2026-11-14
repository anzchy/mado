import AppKit
import Testing

@MainActor private func issue683MouseEvent(_ type: NSEvent.EventType, in panel: NSWindow, at point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                   clickCount: 1, pressure: 1))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683WindowHoverTracksThroughPanelEventPath() throws {
    let screen = try #require(NSScreen.main)
    let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    let candidates = [
        ScreenCaptureKitScreen.WindowCandidate(id: 41, frame: CGRect(x: screen.frame.minX + 20,
            y: top - screen.frame.minY - 80, width: 60, height: 60)),
        ScreenCaptureKitScreen.WindowCandidate(id: 42, frame: CGRect(x: screen.frame.minX + 100,
            y: top - screen.frame.minY - 80, width: 60, height: 60))
    ]
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window, windows: candidates) { _ in }
    defer { panel.orderOut(nil) }
    panel.sendEvent(try issue683MouseEvent(.mouseMoved, in: panel, at: CGPoint(x: 30, y: 30)))
    #expect(panel.highlightedWindowID == 41)
    panel.sendEvent(try issue683MouseEvent(.mouseMoved, in: panel, at: CGPoint(x: 110, y: 30)))
    #expect(panel.highlightedWindowID == 42)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683WindowOverlayAcceptsFirstClickOnAnotherDisplay() throws {
    let screen = try #require(NSScreen.main)
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window) { _ in }
    defer { panel.orderOut(nil) }
    let event = try issue683MouseEvent(.leftMouseDown, in: panel, at: CGPoint(x: 20, y: 20))
    #expect(panel.contentView?.acceptsFirstMouse(for: event) == true)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683WindowEscapeCancelsThroughPanelEventPath() throws {
    let screen = try #require(NSScreen.main)
    var cancelled = false
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window) { cancelled = $0 == nil }
    defer { panel.orderOut(nil) }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    panel.sendEvent(event)
    #expect(cancelled)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683WindowEscapeTearsDownOverlayBeforeCancelCallback() throws {
    let screen = try #require(NSScreen.main)
    var closedInCallback = false
    var panel: CaptureSelectionPanel!
    panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window) { target in
        closedInCallback = target == nil && !panel.isVisible
    }
    defer { panel.orderOut(nil) }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    panel.sendEvent(event)
    #expect(closedInCallback)
}
