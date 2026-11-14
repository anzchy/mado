import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func captureSettingsFixture() -> SettingsPanelWindow {
    let preferences = InMemoryDisplayPreferencesStore()
    return SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue682-\(UUID().uuidString)")!)
}

@MainActor private func captureSettingsView(_ id: String, in panel: SettingsPanelWindow) -> NSView? {
    func find(_ view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }
    return panel.window.contentView.flatMap(find)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureSettingsTabPrecedesUpdatesAndStartsOff() throws {
    let panel = captureSettingsFixture()
    defer { panel.window.close() }
    let section = try #require(SettingsSection(rawValue: "capture"))
    let captureIndex = try #require(SettingsSection.allCases.firstIndex(of: section))
    let updateIndex = try #require(SettingsSection.allCases.firstIndex(of: .update))
    #expect(captureIndex + 1 == updateIndex)
    panel.select(section)
    let switchButton = try #require(captureSettingsView("settings.capture.enabled", in: panel) as? NSButton)
    #expect(switchButton.state == .off)
    #expect(switchButton.isEnabled)
    let note = try #require(captureSettingsView("settings.capture.permission-note", in: panel) as? NSTextField)
    #expect(note.stringValue == "在 macOS 15 及以后，系统会不定期再次询问是否允许 Mado 截取屏幕。这是系统要求，选择允许即可继续截图。")
}
