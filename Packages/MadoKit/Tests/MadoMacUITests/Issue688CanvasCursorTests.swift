import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

private final class CursorOverlayControl: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue688CanvasMouseMotionChecksSelectableTextBeforeCursorUpdate() throws {
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 240, height: 180), session: ViewerSession())
    var points: [CGPoint] = []
    var overText = true
    canvas.onTextPointer = { point in points.append(point); return overText }
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 42, y: 60),
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
        clickCount: 0, pressure: 0))
    canvas.mouseMoved(with: event)
    #expect(points.count == 1)
    overText = false
    canvas.cursorUpdate(with: event)
    #expect(points.count == 2)
    let canvasPoint = canvas.convert(event.locationInWindow, from: nil)
    #expect(points.allSatisfy { $0 == canvasPoint })
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue688CanvasMouseMotionLeavesOverlayCursorAlone() throws {
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 240, height: 180), session: ViewerSession())
    let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = canvas
    let overlay = CursorOverlayControl(frame: NSRect(x: 20, y: 40, width: 100, height: 50))
    var pointerCalls = 0
    canvas.onTextPointer = { _ in pointerCalls += 1; return true }
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 42, y: 60),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 0, pressure: 0))
    NSCursor.arrow.set()
    let imageEvent = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 200, y: 100),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 2, clickCount: 0, pressure: 0))
    canvas.mouseMoved(with: imageEvent)
    #expect(NSCursor.current == .iBeam)
    canvas.addSubview(overlay)
    canvas.mouseMoved(with: event)
    #expect(pointerCalls == 1, "the overlay move must not ask the canvas for text")
    #expect(NSCursor.current == .arrow, "leaving selected text for a control restores the arrow")
}
