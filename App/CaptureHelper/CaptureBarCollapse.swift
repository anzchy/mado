import AppKit

/// The menu bar icon shown while the Capture Bar is collapsed.
@MainActor protocol CaptureStatusItemHandle: AnyObject {
    func remove()
}

/// Collapse to the menu bar and restore (#685, grilling 2.2): the bar hides and a menu bar icon appears; clicking the
/// icon, or the show / collapse shortcut, brings the bar back. There is no menu-bar menu (capture-bar.html:19-20).
@MainActor final class CaptureBarCollapseController {
    typealias StatusItemFactory = @MainActor (_ toolTip: String, _ label: String, _ action: @escaping () -> Void)
        -> CaptureStatusItemHandle

    private let bar: NSWindow
    private let localize: (String) -> String
    private let makeStatusItem: StatusItemFactory
    private let changed: (Bool) -> Void
    private var item: CaptureStatusItemHandle?

    var isCollapsed: Bool { item != nil }

    init(bar: NSWindow, localize: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) },
         makeStatusItem: @escaping StatusItemFactory = SystemCaptureStatusItem.make,
         changed: @escaping (Bool) -> Void = { _ in }) {
        self.bar = bar
        self.localize = localize
        self.makeStatusItem = makeStatusItem
        self.changed = changed
    }

    func collapse() {
        guard item == nil else { return }
        bar.orderOut(nil)
        // capture-bar.html:99: title 点按显示截图工具条, label Mado 截图：点按显示截图工具条.
        item = makeStatusItem(localize("Click to show the Capture Bar"),
                              localize("Mado Capture: click to show the Capture Bar")) { [weak self] in self?.restore() }
        changed(true)
    }

    func restore() {
        guard let item else { return }
        item.remove()
        self.item = nil
        bar.orderFrontRegardless()
        changed(false)
    }

    func toggle() {
        if isCollapsed { restore() } else { collapse() }
    }
}

/// An `NSStatusItem` with the capture glyph and no menu: a click restores the bar.
@MainActor final class SystemCaptureStatusItem: NSObject, CaptureStatusItemHandle {
    private let item: NSStatusItem
    private let action: () -> Void

    private init(toolTip: String, label: String, action: @escaping () -> Void) {
        self.action = action
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: label)
            button.toolTip = toolTip
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier("capture.status-item")
            button.target = self
            button.action = #selector(clicked)
        }
    }

    static func make(toolTip: String, label: String, action: @escaping () -> Void) -> CaptureStatusItemHandle {
        SystemCaptureStatusItem(toolTip: toolTip, label: label, action: action)
    }

    @objc private func clicked() { action() }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}
