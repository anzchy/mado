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
    let switchButton = try #require(captureSettingsView("settings.capture.enabled", in: panel) as? NSSwitch)
    #expect(switchButton.state == .off)
    #expect(switchButton.isEnabled)
    let note = try #require(captureSettingsView("settings.capture.permission-note", in: panel) as? NSTextField)
    #expect(note.stringValue == "在 macOS 15 及以后，系统会不定期再次询问是否允许 Mado 截取屏幕。这是系统要求，选择允许即可继续截图。")
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
    #expect(abs(folderLabel.frame.width - 120) <= 1)
    #expect(abs(folder.frame.minX - folderLabel.frame.maxX - 16) <= 1)
    #expect(note.stringValue == "在 macOS 15 及以后，系统会不定期再次询问是否允许 Mado 截取屏幕。这是系统要求，选择允许即可继续截图。")
    #expect(ocr.isEnabledForCaptureSettings)
    for id in ["settings.capture.folder-change", "settings.capture.after-save", "settings.capture.shortcut-region"] {
        let control = try #require(captureSettingsView(id, in: panel) as? NSControl)
        #expect(!control.isEnabled)
        #expect(control.alphaValue < 1)
    }
}

private extension NSView {
    var isEnabledForCaptureSettings: Bool { !isHidden && alphaValue == 1 }
}


@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureBarMatchesPinnedInternalLayout() throws {
    let bar = CaptureBarView(captureAction: {})
    #expect(abs(bar.frame.width - 562) <= 1)
    #expect(abs(bar.frame.height - 40) <= 1)
    let grip = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.grip" })
    #expect(abs(grip.frame.width - 32) <= 1)
    #expect(abs(grip.frame.height - 32) <= 1)
    let region = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.region" } as? NSButton)
    #expect(abs(region.frame.height - 32) <= 1)
    #expect(region.title == "区域截图")
    #expect(region.toolTip == "区域截图")
    let screen = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.screen" } as? NSButton)
    #expect(screen.isEnabled)
    #expect(screen.title == "全屏截图")
    let expected = ["capture.grip", "capture.region", "capture.window", "capture.screen", "capture.text", "capture.mado", "capture.collapse"]
    let actual = bar.subviews.compactMap { $0.accessibilityIdentifier() }.filter { expected.contains($0) }
    #expect(actual == expected)
    for id in ["capture.region", "capture.window", "capture.text", "capture.collapse"] {
        let button = try #require(bar.subviews.first { $0.accessibilityIdentifier() == id } as? NSButton)
        #expect(!button.isEnabled)
        #expect(button.toolTip?.contains("⌃") != true)
    }
}
