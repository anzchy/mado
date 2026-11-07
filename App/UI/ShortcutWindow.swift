import AppKit
import MadoMacUI

@MainActor
final class ShortcutWindow: NSObject {
    static let contentSize = NSSize(width: 820, height: 502)
    let window: NSWindow
    private let appearanceAdapter: WindowAppearanceAdapter

    init(menu: NSMenu, appearanceAdapter: WindowAppearanceAdapter) {
        self.appearanceAdapter = appearanceAdapter
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = String(localized: "Keyboard Shortcuts")
        window.identifier = NSUserInterfaceItemIdentifier("keyboard-shortcuts.window")
        window.isReleasedWhenClosed = false
        window.contentView = ShortcutListView(frame: NSRect(origin: .zero, size: Self.contentSize),
            catalog: ShortcutCatalog(menu: menu))
        window.center()
    }

    func show() {
        appearanceAdapter.register(window)
        window.makeKeyAndOrderFront(nil)
    }
}
