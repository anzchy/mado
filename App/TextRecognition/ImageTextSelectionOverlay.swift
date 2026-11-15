import AppKit

/// Drawn over the canvas image; input remains owned by CanvasView.
@MainActor final class ImageTextSelectionOverlay: NSView {
    var selection: ImageTextSelection? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let selection else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).setFill()
        for rect in selection.selectionRects {
            if rect.intersects(dirtyRect) { NSBezierPath(rect: rect).fill() }
        }
    }
}
