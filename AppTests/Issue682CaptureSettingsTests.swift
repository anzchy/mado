import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func captureSettingsFixture(
    capturePreferences: (any CaptureBarPreferencePort)? = nil,
    captureLocalize: @escaping (String) -> String = { $0 }
) -> SettingsPanelWindow {
    let preferences = InMemoryDisplayPreferencesStore()
    return SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue682-\(UUID().uuidString)")!,
        capturePreferences: capturePreferences ?? CaptureBarTestPreferences(),
        captureLocalize: captureLocalize)
}

private actor CaptureBarTestPreferences: CaptureBarPreferencePort {
    private var enabled = false
    func isCaptureBarEnabled() -> Bool { enabled }
    func setCaptureBarEnabled(_ enabled: Bool) { self.enabled = enabled }
    func capturePermissionState() -> CapturePermissionState? { .granted }
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
    let switchButton = try #require(captureSettingsView("settings.capture.enabled", in: panel) as? NSSwitch)
    #expect(switchButton.state == .off)
    #expect(switchButton.isEnabled)
    let note = try #require(captureSettingsView("settings.capture.permission-note", in: panel) as? NSTextField)
    #expect(note.stringValue == "On macOS 15 and later, the system may ask again from time to time whether Mado can capture the screen. This is required by macOS; choose Allow to continue taking screenshots.")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureDesignRowsMatchPinnedSettings() throws {
    let panel = captureSettingsFixture()
    defer { panel.window.close() }
    panel.select(.capture)
    let bar = try #require(captureSettingsView("settings.capture.enabled", in: panel) as? NSSwitch)
    let folder = try #require(captureSettingsView("settings.capture.folder", in: panel) as? NSTextField)
    let folderLabel = try #require(captureSettingsView("settings.capture.folder-label", in: panel) as? NSTextField)
    let note = try #require(captureSettingsView("settings.capture.permission-note", in: panel) as? NSTextField)
    let ocr = try #require(captureSettingsView("settings.capture.ocr", in: panel) as? NSView)
    #expect(abs(bar.frame.width - 32) <= 1)
    #expect(abs(bar.frame.height - 18) <= 1)
    #expect(folder.stringValue == "~/Downloads")
    #expect(folderLabel.alignment == .right)
    #expect(folderLabel.frame.width >= 120)
    #expect(abs(folder.frame.minX - folderLabel.frame.maxX - 16) <= 1)
    #expect(note.stringValue == "On macOS 15 and later, the system may ask again from time to time whether Mado can capture the screen. This is required by macOS; choose Allow to continue taking screenshots.")
    #expect(ocr.isEnabledForCaptureSettings)
    let cloud = try #require(captureSettingsView("settings.capture.ocr-cloud", in: panel) as? NSSwitch)
    let service = try #require(captureSettingsView("settings.capture.ocr-service", in: panel) as? NSPopUpButton)
    #expect(!cloud.isEnabled)
    #expect(!service.isEnabled)
    #expect(captureSettingsView("settings.capture.after-action", in: panel) == nil)
    let shortcut1 = try #require(captureSettingsView("settings.capture.shortcut-region", in: panel))
    let shortcut2 = try #require(captureSettingsView("settings.capture.shortcut-1", in: panel))
    #expect(abs(shortcut1.frame.midY - shortcut2.frame.midY) == 38)
    #expect(captureSettingsView("settings.capture.privacy-hint", in: panel) != nil)
    #expect(captureSettingsView("settings.capture.login-hint", in: panel) != nil)
    #expect(captureSettingsView("settings.capture.filename-hint", in: panel) != nil)
    #expect(captureSettingsView("settings.capture.system-shortcuts-hint", in: panel) != nil)
    for id in ["settings.capture.folder-change", "settings.capture.after-save", "settings.capture.shortcut-region"] {
        let control = try #require(captureSettingsView(id, in: panel) as? NSControl)
        #expect(!control.isEnabled)
        #expect(control.alphaValue < 1)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureSettingsReadsInjectedSwitchAndPermission() async throws {
    let preferences = CaptureBarTestPreferences()
    await preferences.setCaptureBarEnabled(true)
    let panel = captureSettingsFixture(capturePreferences: preferences)
    defer { panel.window.close() }
    panel.select(.capture)
    let toggle = try #require(captureSettingsView("settings.capture.enabled", in: panel) as? NSSwitch)
    let status = try #require(captureSettingsView("settings.capture.permission-status", in: panel) as? NSTextField)
    for _ in 0..<100 where toggle.state != .on { await Task.yield() }
    #expect(toggle.state == .on)
    #expect(status.stringValue == "Granted")
    await preferences.setCaptureBarEnabled(false)
    panel.select(.capture)
    for _ in 0..<100 where toggle.state != .off { await Task.yield() }
    #expect(toggle.state == .off)
}

private extension NSView {
    var isEnabledForCaptureSettings: Bool { !isHidden && alphaValue == 1 }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue682SettingsControlTitlesFitInEnglishAndChinese() throws {
    for locale in ["en", "zh-Hans"] {
        let catalog = try captureCatalog(locale)
        let panel = captureSettingsFixture(captureLocalize: { catalog[$0] ?? $0 })
        defer { panel.window.close() }
        panel.select(.capture)
        for id in ["settings.capture.enabled.title", "settings.capture.login.title",
                   "settings.capture.after-save.title", "settings.capture.after-copy.title",
                   "settings.capture.shortcut-label-3", "settings.capture.shortcut-label-4"] {
            let field = try #require(captureSettingsView(id, in: panel) as? NSTextField)
            let width = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
            #expect(width <= field.frame.width)
        }
        for id in ["settings.capture.folder-change", "settings.capture.shortcut-region"] {
            let button = try #require(captureSettingsView(id, in: panel) as? NSButton)
            let width = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
            #expect(width + 12 <= button.frame.width)
        }
    }
}


@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureBarMatchesPinnedInternalLayout() throws {
    let bar = CaptureBarView(captureAction: {})
    #expect(bar.frame.width >= 562)
    #expect(abs(bar.frame.height - 40) <= 1)
    let grip = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.grip" })
    #expect(abs(grip.frame.width - 32) <= 1)
    #expect(abs(grip.frame.height - 32) <= 1)
    let region = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.region" } as? NSButton)
    #expect(abs(region.frame.height - 32) <= 1)
    #expect(region.title == String(localized: "Region Capture"))
    #expect(region.toolTip == String(localized: "Region Capture"))
    let screen = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.screen" } as? NSButton)
    #expect(screen.isEnabled)
    #expect(screen.title == String(localized: "Full Screen Capture"))
    let expected = ["capture.grip", "capture.region", "capture.window", "capture.screen", "capture.text", "capture.mado", "capture.collapse"]
    let actual = bar.subviews.compactMap { $0.accessibilityIdentifier() }.filter { expected.contains($0) }
    #expect(actual == expected)
    for id in ["capture.region", "capture.window", "capture.text", "capture.collapse"] {
        let button = try #require(bar.subviews.first { $0.accessibilityIdentifier() == id } as? NSButton)
        #expect(!button.isEnabled)
        #expect(button.toolTip?.contains("⌃") != true)
    }
}
