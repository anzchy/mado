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

@MainActor @Test(.timeLimit(.minutes(3))) func issue218PinnedSettingsSidebarRenderedFrames() throws {
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

// State 35: 10 pt inside each 164 pt row, 16 pt icon, 8 pt gap, 30 pt rows, 2 pt pitch.
@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue863SettingsSidebarMetricsInBothLanguages(_ locale: String) throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let sidebar = try #require(settingsView("settings.sidebar", in: root))
    let titles = locale == "zh-Hans" ? ["通用", "显示", "缓存", "截图", "更新", "关于"]
                                     : ["General", "Display", "Cache", "Screenshots", "Updates", "About"]
    for (index, section) in SettingsSection.allCases.enumerated() {
        panel.select(section)
        let row = try #require(settingsView("settings.section.\(section.rawValue)", in: root) as? NSButton)
        let icon = try #require(settingsView("settings.sidebar.icon.\(section.rawValue)", in: root))
        let text = try #require(settingsView("settings.sidebar.label.\(section.rawValue)", in: root) as? NSTextField)
        text.stringValue = titles[index] // Frames are independent of language; check both real string widths.
        row.layoutSubtreeIfNeeded()
        #expect(row.state == .on)
        #expect(abs(row.frame.minX - 8) < 0.5)
        #expect(abs(row.frame.height - 30) < 0.5)
        #expect(abs(icon.frame.minX - 10) < 0.5)
        #expect(abs(icon.frame.width - 16) < 0.5)
        #expect(abs(icon.frame.height - 16) < 0.5)
        #expect(abs(text.frame.minX - icon.frame.maxX - 8) < 0.5)
        #expect(text.intrinsicContentSize.width <= text.frame.width - 4)
        #expect(row.bounds.contains(icon.frame) && row.bounds.contains(text.frame))
        if index > 0 {
            let previous = try #require(settingsView("settings.section.\(SettingsSection.allCases[index - 1].rawValue)", in: root))
            #expect(abs(previous.frame.minY - row.frame.maxY - 2) < 0.5)
        }
        #expect(row.frame.minY >= sidebar.bounds.minY)
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        panel.window.appearance = NSAppearance(named: appearance)
        panel.select(.general)
        let selected = try #require(settingsView("settings.section.general", in: root) as? NSButton)
        let unselected = try #require(settingsView("settings.section.display", in: root) as? NSButton)
        #expect(selected.state == .on && unselected.state == .off)
        for row in [selected, unselected] {
            let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
            let title = try #require(row.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(abs(title.frame.minX - icon.frame.maxX - 8) < 0.5)
            #expect(row.bounds.contains(icon.frame) && row.bounds.contains(title.frame))
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218SettingsSectionPersistsAcrossWindowInstances() {
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

@MainActor @Test(.timeLimit(.minutes(3))) func issue863Fix1SidebarFocusRingCoversTheWholeRow() throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let row = try #require(settingsView("settings.section.general", in: root) as? NSButton)
    #expect(row.focusRingMaskBounds == row.bounds)
}
