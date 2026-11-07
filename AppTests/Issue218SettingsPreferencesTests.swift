import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func settingsFixture() -> (SettingsPanelWindow, InMemoryDisplayPreferencesStore, UserDefaults) {
    let preferences = InMemoryDisplayPreferencesStore()
    let defaults = UserDefaults(suiteName: "issue218-preferences-\(UUID().uuidString)")!
    let cache = ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let panel = SettingsPanelWindow(cache: cache, appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
                                    preferencesStore: preferences, defaults: defaults)
    return (panel, preferences, defaults)
}

@MainActor private func settingsView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = settingsView(id, in: child) { return found }
    }
    return nil
}

@MainActor @Test func issue218SettingsAndMenuShareAppearanceAndTools() throws {
    let (panel, preferences, _) = settingsFixture()
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: preferences, openWithoutWindow: {}, openSettings: {}, openDiagnostics: {})
    defer { panel.window.close(); NSApp.mainMenu = previousMenu; withExtendedLifetime(menu) {} }
    let root = try #require(panel.window.contentView)
    let appearance = try #require(settingsView("settings.appearance.dark", in: root) as? NSButton)
    appearance.performClick(nil)
    #expect(preferences.value.appearance == .dark)
    #expect(appearance.accessibilityRole() == .radioButton)
    let darkMenu = try #require(NSApp.mainMenu?.items
        .first(where: { $0.title == String(localized: "View") })?.submenu?.items
        .first(where: { $0.accessibilityIdentifier() == "prefs.appearance.menu" })?.submenu?.items
        .first(where: { $0.accessibilityIdentifier() == "prefs.appearance.dark.menu" }))
    #expect(menu.validateMenuItem(darkMenu))
    #expect(darkMenu.state == .on)
    let tools = try #require(settingsView("settings.always-show-tools", in: root) as? NSButton)
    tools.performClick(nil)
    #expect(preferences.value.alwaysShowTools)
    let lightMenu = try #require(darkMenu.menu?.items.first(where: { $0.accessibilityIdentifier() == "prefs.appearance.light.menu" }))
    lightMenu.target?.perform(lightMenu.action, with: lightMenu)
    #expect(menu.validateMenuItem(lightMenu))
    #expect(lightMenu.state == .on)
    let toolsMenu = try #require(NSApp.mainMenu?.items
        .first(where: { $0.title == String(localized: "View") })?.submenu?.items
        .first(where: { $0.identifier?.rawValue == "chrome.always-show-tools" }))
    toolsMenu.target?.perform(toolsMenu.action, with: toolsMenu)
    #expect(menu.validateMenuItem(toolsMenu))
    #expect(toolsMenu.state == .off)
    #expect((settingsView("settings.appearance.light", in: root) as? NSButton)?.state == .on)
    #expect(tools.state == .off)
}
