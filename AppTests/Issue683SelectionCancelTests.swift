import AppKit
import Testing

@MainActor @Test(.timeLimit(.minutes(3))) func issue683EscapeCancelsRegionSelectionBeforeCapture() throws {
    let screen = try #require(NSScreen.main)
    let before = NSPasteboard.general.changeCount
    var results: [Bool] = []
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .region) {
        results.append($0 == nil)
    }
    defer { panel.orderOut(nil) }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                             characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                             isARepeat: false, keyCode: 53))
    panel.keyDown(with: event)
    #expect(results == [true])
    #expect(NSPasteboard.general.changeCount == before)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683ZeroDragCancelsRegionSelectionBeforeCapture() throws {
    let screen = try #require(NSScreen.main)
    let before = NSPasteboard.general.changeCount
    var results: [Bool] = []
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .region) {
        results.append($0 == nil)
    }
    defer { panel.orderOut(nil) }
    let point = CGPoint(x: 20, y: 20)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                               timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                               eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                             eventNumber: 2, clickCount: 1, pressure: 0))
    panel.contentView?.mouseDown(with: down)
    panel.contentView?.mouseUp(with: up)
    #expect(results == [true])
    #expect(NSPasteboard.general.changeCount == before)
}
