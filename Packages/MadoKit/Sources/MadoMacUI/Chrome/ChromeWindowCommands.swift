import AppKit

/// Standard window action; the App installs it in File and AppKit resolves the active window.
public enum ChromeWindowCommands {
    @discardableResult public static func addClose(to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: String(localized: "Close"),
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.keyEquivalentModifierMask = [.command]
        return item
    }
}
