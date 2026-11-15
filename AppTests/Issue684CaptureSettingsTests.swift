import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #684 Settings › Screenshots 「截图之后」: design page 35 ?section=capture — 存储到文件夹 and 拷贝到剪贴板 both on,
// greyed and not editable while the Capture Bar is off (grilling 5.2).

private actor BarSwitch: CaptureBarPreferencePort {
    var enabled: Bool
    init(_ enabled: Bool) { self.enabled = enabled }
    func isCaptureBarEnabled() -> Bool { enabled }
    func setCaptureBarEnabled(_ enabled: Bool) { self.enabled = enabled }
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

private actor OutputSwitches: CaptureOutputPreferencePort {
    var policy = CaptureOutputPolicy.standard
    func outputPolicy() -> CaptureOutputPolicy { policy }
    func setSavesToFolder(_ enabled: Bool) { policy.savesToFolder = enabled }
    func setCopiesToClipboard(_ enabled: Bool) { policy.copiesToClipboard = enabled }
}

@MainActor private func settings(bar: BarSwitch, output: OutputSwitches) -> SettingsPanelWindow {
    let preferences = InMemoryDisplayPreferencesStore()
    return SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue684-\(UUID().uuidString)")!,
        capturePreferences: bar, captureOutputPreferences: output, captureLocalize: { $0 })
}

@MainActor private func find(_ id: String, in panel: SettingsPanelWindow) -> NSView? {
    func walk(_ view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = walk(child) { return found } }
        return nil
    }
    return panel.window.contentView.flatMap(walk)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue684SettingsSwitchesDefaultOnPersistAndGrey() async throws {
    let bar = BarSwitch(true)
    let output = OutputSwitches()
    let panel = settings(bar: bar, output: output)
    defer { panel.window.close() }
    panel.select(.capture)
    let save = try #require(find("settings.capture.after-save", in: panel) as? NSSwitch)
    let copy = try #require(find("settings.capture.after-copy", in: panel) as? NSSwitch)
    for _ in 0..<200 where !save.isEnabled { await Task.yield() }
    #expect(save.state == .on)
    #expect(copy.state == .on)
    #expect(save.isEnabled && copy.isEnabled)
    #expect(save.alphaValue == 1 && copy.alphaValue == 1)
    save.performClick(nil)
    for _ in 0..<200 where await output.policy.savesToFolder { await Task.yield() }
    #expect(await output.policy == CaptureOutputPolicy(savesToFolder: false, copiesToClipboard: true))
    copy.performClick(nil)
    for _ in 0..<200 where await output.policy.copiesToClipboard { await Task.yield() }
    #expect(await output.policy == CaptureOutputPolicy(savesToFolder: false, copiesToClipboard: false))

    let reopened = settings(bar: bar, output: output)
    defer { reopened.window.close() }
    reopened.select(.capture)
    let save2 = try #require(find("settings.capture.after-save", in: reopened) as? NSSwitch)
    for _ in 0..<200 where save2.state != .off || !save2.isEnabled { await Task.yield() }
    #expect(save2.state == .off)

    let off = settings(bar: BarSwitch(false), output: OutputSwitches())
    defer { off.window.close() }
    off.select(.capture)
    let saveOff = try #require(find("settings.capture.after-save", in: off) as? NSSwitch)
    let copyOff = try #require(find("settings.capture.after-copy", in: off) as? NSSwitch)
    for _ in 0..<200 where saveOff.state != .on { await Task.yield() }
    #expect(saveOff.state == .on && copyOff.state == .on)
    #expect(!saveOff.isEnabled && !copyOff.isEnabled)
    #expect(saveOff.alphaValue < 1 && copyOff.alphaValue < 1)
    #expect(CaptureDeferredSettingsControls.tickets["settings.capture.after-save"] == nil)
    #expect(CaptureDeferredSettingsControls.tickets["settings.capture.after-copy"] == nil)
}
