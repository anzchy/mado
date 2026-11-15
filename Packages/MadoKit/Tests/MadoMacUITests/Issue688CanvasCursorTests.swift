import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

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
