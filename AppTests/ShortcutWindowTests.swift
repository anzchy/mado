import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor @Test func issue219HelpOpensOneShortcutWindowAndCommandWClosesIt() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    var shortcutWindow: ShortcutWindow!
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: {},
        openShortcuts: { shortcutWindow.show() }, windowController: { nil })
    shortcutWindow = ShortcutWindow(menu: try #require(NSApp.mainMenu),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: InMemoryDisplayPreferencesStore()))
    defer {
        shortcutWindow.window.close()
        NSApp.mainMenu = previousMenu
        withExtendedLifetime(menu) {}
        withExtendedLifetime(shortcutWindow) {}
    }
    let main = try #require(NSApp.mainMenu)
    let help = try #require(main.items.first { $0.title == "Help" }?.submenu)
    let shortcuts = try #require(help.items.first { $0.identifier?.rawValue == "help.keyboard-shortcuts.menu" })
    #expect(menu.validateMenuItem(shortcuts))
    #expect(shortcuts.isEnabled)
    #expect(shortcuts.keyEquivalent.isEmpty)
    #expect(shortcuts.action != nil)
    #expect(shortcuts.title == String(localized: "Keyboard Shortcuts"))
    #expect(shortcuts.accessibilityLabel()?.contains("Coming Soon") == false)
    #expect(shortcuts.accessibilityLabel()?.contains("即将推出") == false)

    let action = try #require(shortcuts.action)
    #expect(NSApp.sendAction(action, to: shortcuts.target, from: shortcuts))
    let first = shortcutWindow.window
    #expect(first.isVisible)
    #expect(first.title == String(localized: "Keyboard Shortcuts"))
    #expect(first.styleMask.contains(.titled))
    #expect(first.styleMask.contains(.closable))
    #expect(first.identifier?.rawValue == "keyboard-shortcuts.window")
    let content = try #require(first.contentView)
    #expect(content.frame.size == NSSize(width: 820, height: 502))
    #expect(first.contentRect(forFrameRect: first.frame).size == content.frame.size)
    #expect(NSApp.sendAction(action, to: shortcuts.target, from: shortcuts))
    #expect(shortcutWindow.window === first)

    let file = try #require(main.items.first { $0.title == "File" }?.submenu)
    let close = try #require(file.items.first { $0.keyEquivalent == "w" })
    #expect(close.keyEquivalentModifierMask == [.command])
    #expect(close.action == #selector(NSWindow.performClose(_:)))
    #expect(NSApp.sendAction(try #require(close.action), to: first, from: close))
    #expect(!first.isVisible)
}

@MainActor @Test func issue219RealMainMenuCatalogListsEverySourceExactlyOnce() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: {}, windowController: { nil })
    defer { NSApp.mainMenu = previousMenu; withExtendedLifetime(menu) {} }
    let main = try #require(NSApp.mainMenu)
    let catalog = ShortcutCatalog(menu: main, language: .english)
    let sources = catalog.cards.flatMap { $0.rows.flatMap { $0.sources.map(\.id) } }
    var keyedItems: [NSMenuItem] = []
    func collect(_ menu: NSMenu) {
        for item in menu.items {
            if item.submenu?.title == "Edit" { continue }
            if !item.keyEquivalent.isEmpty { keyedItems.append(item) }
            if let submenu = item.submenu { collect(submenu) }
        }
    }
    collect(main)
    #expect(!keyedItems.isEmpty)
    for item in keyedItems {
        let source = catalog.source(for: item)
        #expect(source != nil, "unmapped keyed menu item: \(item.title) \(item.action.map(NSStringFromSelector) ?? "")")
        if let source { #expect(sources.filter { $0 == source.id }.count == 1, "wrong source count for \(item.title)") }
    }
}

@MainActor @Test func issue219AppDelegateShowShortcutsReusesItsCachedWindow() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: {}, windowController: { nil })
    let delegate = AppDelegate()
    defer {
        delegate.shortcutWindow?.window.close()
        NSApp.mainMenu = previousMenu
        withExtendedLifetime(menu) {}
    }
    delegate.showShortcuts()
    let first = try #require(delegate.shortcutWindow?.window)
    #expect(first.isVisible)
    delegate.showShortcuts()
    #expect(delegate.shortcutWindow?.window === first)
}
