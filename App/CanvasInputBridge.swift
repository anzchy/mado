import AppKit
import MadoMacUI

/// Only extracts the native gesture fields; policy and Session updates live in the reusable canvas.
@MainActor
final class CanvasInputBridge: CanvasView, NSMenuItemValidation {
    var onCopyAction: (() -> Void)?
    var onCanCopy: ((NSMenuItem) -> Bool)?
    @objc func copy(_ sender: Any?) { onCopyAction?() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return onCanCopy?(menuItem) ?? false }
        return true
    }
    override func magnify(with event: NSEvent) {
        magnify(by: Double(event.magnification), at: convert(event.locationInWindow, from: nil))
    }
}
