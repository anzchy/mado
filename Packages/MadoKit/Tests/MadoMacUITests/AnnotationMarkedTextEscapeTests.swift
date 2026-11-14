import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #692 fix r1 (opus M1): Esc while an input method is composing (Pinyin's marked text) belongs to the input method:
// the overlay does not commit the text. If the Esc still reaches the field's command (no input method took it), the
// composition is dropped, as Pinyin's Esc does, and typing continues.

@MainActor @Suite struct AnnotationMarkedTextEscapeTests {
    @Test(.timeLimit(.minutes(2))) func issue692MarkedTextEscapeDropsTheCompositionNotTheText() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let overlay = AnnotationOverlayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.contentView = overlay
        overlay.transform = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
        overlay.imageSize = CGSize(width: 1600, height: 2400)
        overlay.isActive = true
        overlay.tool = .text
        var commits: [String] = []
        overlay.onCommitText = { _, text, _, _ in commits.append(text) }
        let point = overlay.convert(CGPoint(x: 600, y: 400), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { overlay.mouseDown(with: event) } else { overlay.mouseUp(with: event) }
        }
        let field = try #require(overlay.textEditor)
        field.stringValue = "从这里"
        let composing = NSTextView()
        composing.setMarkedText("shang", selectedRange: NSRange(location: 5, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(composing.hasMarkedText())
        #expect(overlay.control(field, textView: composing, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                "the Esc is used up")
        #expect(overlay.isEditingText && commits.isEmpty, "the text is not committed while composing")
        #expect(!composing.hasMarkedText(), "the composition is dropped")
        #expect(overlay.control(field, textView: composing, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!overlay.isEditingText && commits == ["从这里"], "the next Esc ends the typing")
    }
}
