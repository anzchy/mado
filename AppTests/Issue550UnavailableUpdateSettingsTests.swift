import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func issue550Settings(_ port: SparkleUpdatePort) -> SettingsPanelWindow {
    let preferences = InMemoryDisplayPreferencesStore()
    let defaults = UserDefaults(suiteName: "issue550-settings-\(UUID().uuidString)")!
    let cache = ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let panel = SettingsPanelWindow(cache: cache,
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences, defaults: defaults, updates: port)
    panel.select(.update)
    return panel
}

@MainActor @Test func issue550SettingsWithoutFeedKeepsBothControlsInertAfterClickAndRefresh() throws {
    for info: [String: Any] in [[:], ["SUFeedURL": ""], ["SUFeedURL": " \n\t"]] {
        let port = SparkleUpdatePort(infoDictionary: info)
        let panel = issue550Settings(port)
        defer { panel.window.close() }
        let automatic = try #require(issue220View("settings.update.automatic", in: panel) as? NSButton)
        let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
        #expect(!automatic.isEnabled)
        #expect(!check.isEnabled)
        let initial = automatic.state
        #expect(initial == .off)
        automatic.performClick(nil)
        check.performClick(nil)
        #expect(automatic.state == initial)
        #expect(!port.automaticallyChecksForUpdates && !port.canCheckForUpdates)
        #expect(port.lastUpdateCheckDate == nil)
        panel.select(.general)
        panel.select(.update)
        #expect(!automatic.isEnabled && !check.isEnabled)
        #expect(automatic.state == initial)
        let pane = try #require(issue220View("settings.pane.update", in: panel))
        let labels = pane.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(String(localized: "Updates are not available in this build.")))
        #expect(!labels.contains(String(localized: "Mado contacts GitHub only to check for updates and sends no system information.")))
    }
}

@MainActor @Test func issue550SettingsWithRealStoppedFeedKeepsAutomaticAvailableAndPrivacyHint() throws {
    let port = SparkleUpdatePort(infoDictionary: ["SUFeedURL": "https://example.com/feed.xml"])
    let panel = issue550Settings(port)
    defer { panel.window.close() }
    let automatic = try #require(issue220View("settings.update.automatic", in: panel) as? NSButton)
    let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
    #expect(!port.canCheckForUpdates)
    #expect(automatic.isEnabled)
    #expect(!check.isEnabled)
    let pane = try #require(issue220View("settings.pane.update", in: panel))
    let labels = pane.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
    #expect(labels.contains(String(localized: "Mado contacts GitHub only to check for updates and sends no system information.")))
    #expect(!labels.contains(String(localized: "Updates are not available in this build.")))
}

@MainActor @Test func issue550UnavailableUpdateExplanationHasEnglishAndChineseTextThatFits() throws {
    let key = "Updates are not available in this build."
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    for (language, expected) in [("en", key), ("zh-Hans", "此版本暂不提供更新。")] {
        let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any])
        #expect(unit["state"] as? String == "translated")
        #expect(unit["value"] as? String == expected)
        let field = NSTextField(labelWithString: expected)
        field.font = DesignMetrics.font("uiSmall")
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        #expect(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 390, height: 1000)).height <= 36)
    }
}
