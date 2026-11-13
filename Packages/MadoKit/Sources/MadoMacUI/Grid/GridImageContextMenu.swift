import AppKit

@MainActor public protocol GridContextMenuPresenting: AnyObject {
    func present(_ menu: NSMenu, at point: NSPoint, in view: NSView)
}

/// A standard AppKit menu; its target closure never consults the grid's later selection.
@MainActor public final class GridImageContextMenu: NSObject, NSMenuDelegate {
    public enum Action: String, CaseIterable, Sendable { case quickLook, reveal, copyPath, getInfo }
    public let menu = NSMenu(title: String(localized: "Image Context Menu"))
    public var isAvailable: (Action) -> Bool = { _ in true }
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?
    private let onAction: (Action) -> Void

    public init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        add(.quickLook, title: "Quick Look", key: " ")
        menu.addItem(.separator())
        add(.reveal, title: "Show in Finder")
        add(.copyPath, title: "Copy Path")
        add(.getInfo, title: "Get Info")
        updateAvailability()
    }
    private func add(_ action: Action, title: String, key: String = "") {
        let item = menu.addItem(withTitle: String(localized: String.LocalizationValue(title)),
                                action: #selector(invoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = action.rawValue
        item.identifier = NSUserInterfaceItemIdentifier("grid.context.\(action.rawValue)")
    }
    public func updateAvailability() {
        for item in menu.items {
            guard let raw = item.representedObject as? String, let action = Action(rawValue: raw) else { continue }
            item.isEnabled = isAvailable(action)
        }
    }
    public func menuNeedsUpdate(_ menu: NSMenu) { updateAvailability() }
    public func menuWillOpen(_ menu: NSMenu) { updateAvailability(); onOpen?() }
    public func menuDidClose(_ menu: NSMenu) { onClose?() }
    @objc private func invoke(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw),
              isAvailable(action) else { return }
        onAction(action)
    }
}
