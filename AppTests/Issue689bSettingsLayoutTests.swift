import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #689b dev1 (device run smoke689b-20261116): at the Settings group's fixed width the English masked key line was cut
// to "API Key ••••••••LV…Secret Key ••••••••", and the empty error slot left a ~34 pt gap under "Keys are stored in
// the keychain.". The saved-key line must show in full in both languages, and the error slot takes space only while
// it shows a message.

private actor LayoutSecrets: CloudSecretStorePort {
    var items: [String: String] = [:]
    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? { items[account] }
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) { items[account] = value }
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) { items[account] = nil }
}
private actor LayoutPreferences: CloudRecognitionPreferencePort {
    var enabled = false
    var record: CloudRecognitionConsentRecord?
    func isEnabled() async -> Bool { enabled }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func consentRecord() async -> CloudRecognitionConsentRecord? { record }
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async { self.record = record }
}
private actor LayoutBarOff: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool { false }
    func setCaptureBarEnabled(_ enabled: Bool) {}
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

@MainActor private func layoutPanel(_ locale: String, model: CloudRecognitionSettingsModel) throws -> SettingsPanelWindow {
    let catalog = locale == "en" ? [:] : try captureCatalog(locale)
    let display = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
        defaults: UserDefaults(suiteName: "issue689b-\(UUID().uuidString)")!, capturePreferences: LayoutBarOff(),
        captureLocalize: { catalog[$0] ?? $0 },
        cloudRecognition: CloudRecognitionSettingsEnvironment(model: model, presentConsent: { _, _, _ in }),
        openURL: { _ in })
    panel.select(.capture)
    return panel
}

@MainActor private func find<T: NSView>(_ id: String, in panel: SettingsPanelWindow, as type: T.Type = NSView.self) throws -> T {
    func search(_ view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = search(child) { return found } }
        return nil
    }
    return try #require(panel.window.contentView.flatMap(search) as? T, "\(id)")
}

@MainActor private func singleLineWidth(_ field: NSTextField) -> CGFloat {
    (field.attributedStringValue.size().width).rounded(.up)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue689bSavedKeyLineShowsInFull(_ locale: String) async throws {
    let model = CloudRecognitionSettingsModel(preferences: LayoutPreferences(), keys: BaiduCloudCredentialStore(secrets: LayoutSecrets()))
    // Wide last-four characters: the widest line a real key can produce.
    try await model.saveKeys(apiKey: "AKAKAKAKWWMW", secretKey: "SK")
    let panel = try layoutPanel(locale, model: model)
    defer { panel.window.close() }
    let saved = try find("settings.capture.ocr-saved-keys", in: panel, as: NSTextField.self)
    try await waitUntil { !saved.isHidden }
    let remove = try find("settings.capture.ocr-remove", in: panel, as: NSButton.self)
    let hint = try find("settings.capture.ocr-keys-hint", in: panel, as: NSTextField.self)
    let group = try find("settings.capture.ocr", in: panel)
    #expect(saved.stringValue.hasSuffix("••••••••"))
    #expect(singleLineWidth(saved) <= saved.frame.width, "\(locale): \(singleLineWidth(saved)) > \(saved.frame.width)")
    #expect(!remove.isHidden && !saved.frame.intersects(remove.frame))
    #expect(saved.frame.minX >= 0 && saved.frame.maxX <= group.frame.width + 0.5)
    #expect(remove.frame.minX >= 0 && remove.frame.maxX <= group.frame.width + 0.5)
    #expect(hint.frame.minY >= max(saved.frame.maxY, remove.frame.maxY))
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue689bEmptyErrorSlotTakesNoSpace(_ locale: String) async throws {
    let model = CloudRecognitionSettingsModel(preferences: LayoutPreferences(), keys: BaiduCloudCredentialStore(secrets: LayoutSecrets()))
    let panel = try layoutPanel(locale, model: model)
    defer { panel.window.close() }
    let pill = try find("settings.capture.ocr-pill", in: panel, as: NSTextField.self)
    try await waitUntil { !pill.isHidden }
    let hint = try find("settings.capture.ocr-keys-hint", in: panel, as: NSTextField.self)
    let message = try find("settings.capture.ocr-message", in: panel, as: NSTextField.self)
    let fallback = try find("settings.capture.ocr-fallback-hint", in: panel, as: NSTextField.self)
    let group = try find("settings.capture.ocr", in: panel)
    // No message: the slot is hidden and the fallback note follows the keys note directly.
    #expect(message.stringValue.isEmpty && message.isHidden)
    #expect(fallback.frame.minY - hint.frame.maxY <= 12, "gap \(fallback.frame.minY - hint.frame.maxY)")
    // A message shows between the two notes, whole, and pushes the fallback note down inside the group.
    let toggle = try find("settings.capture.ocr-cloud", in: panel, as: NSSwitch.self)
    toggle.state = .on
    toggle.sendAction(toggle.action, to: toggle.target)
    try await waitUntil { !message.stringValue.isEmpty }
    #expect(!message.isHidden)
    #expect(message.frame.minY >= hint.frame.maxY && fallback.frame.minY >= message.frame.maxY)
    #expect(message.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: .greatestFiniteMagnitude)).height
            <= message.frame.height + 0.5)
    #expect(fallback.frame.maxY <= group.frame.height)
}
