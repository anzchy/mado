import AppKit

@MainActor public protocol GridContextMenuPresenting: AnyObject {
    func present(_ menu: NSMenu, at point: NSPoint, in view: NSView)
}
