import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func settingsFixture() -> (SettingsPanelWindow, InMemoryDisplayPreferencesStore, UserDefaults) {
    let preferences = InMemoryDisplayPreferencesStore()
    let defaults = UserDefaults(suiteName: "issue218-\(UUID().uuidString)")!
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

@MainActor @Test func issue218PinnedSettingsSidebarRenderedFrames() throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    root.layoutSubtreeIfNeeded()
    let sidebar = try #require(settingsView("settings.sidebar", in: root))
    let content = try #require(settingsView("settings.content", in: root))
    // settings.html: .window 760x520, .split 180px 1fr, sidebar padding 10px 8px,
    // rows 30px with 2px gap. Native titlebar occupies 38pt.
    #expect(abs(panel.window.frame.width - 760) < 1)
    #expect(abs(sidebar.frame.width - 180) < 1)
    #expect(abs(content.frame.width - 580) < 1)
    let general = try #require(settingsView("settings.section.general", in: root))
    let display = try #require(settingsView("settings.section.display", in: root))
    #expect(abs(general.frame.minX - 8) < 1)
    #expect(abs(sidebar.frame.maxY - general.frame.maxY - 10) < 1)
    #expect(abs(general.frame.height - 30) < 1)
    #expect(abs(general.frame.minY - display.frame.minY - 32) < 1)
    let pane = try #require(settingsView("settings.pane.general", in: root))
    let heading = try #require(pane.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(abs(heading.frame.minX - 26) < 1)
    #expect(abs(pane.frame.maxY - heading.frame.maxY - 18) < 1)
    #expect(abs((heading.font?.pointSize ?? 0) - 16) < 1)
}

@MainActor @Test func issue218SettingsSectionPersistsAcrossWindowInstances() {
    let (first, _, defaults) = settingsFixture()
    for section in SettingsSection.allCases {
        first.select(section)
        #expect(first.selectedSection == section)
        let preferences = InMemoryDisplayPreferencesStore()
        let second = SettingsPanelWindow(cache: ThumbnailDiskCache(),
            appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
            preferencesStore: preferences, defaults: defaults)
        #expect(second.selectedSection == section)
        second.window.close()
    }
    defaults.set("future-unknown-section", forKey: "settings.selectedSection.v1")
    let preferences = InMemoryDisplayPreferencesStore()
    let fallback = SettingsPanelWindow(cache: ThumbnailDiskCache(),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences, defaults: defaults)
    #expect(fallback.selectedSection == .general)
    first.window.close()
    fallback.window.close()
}
