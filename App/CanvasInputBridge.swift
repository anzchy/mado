import AppKit
import MadoMacUI

/// Only extracts the native gesture fields; policy and Session updates live in the reusable canvas.
@MainActor
final class CanvasInputBridge: CanvasView {
    override func magnify(with event: NSEvent) {
        magnify(by: Double(event.magnification), at: convert(event.locationInWindow, from: nil))
    }
}
