import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #689 slice B: Settings › 截图 › 文字识别 (settings.html lines 174–176; states tree 984d44d2, settings.html SHA256
// a302031f…). The switch turns on only after keys are saved and consent is given (line 23); the first turn-on asks
// with a consent dialog; removing the keys turns it off. The group stays editable with the Capture Bar off.

private actor Secrets: CloudSecretStorePort {
    var items: [String: String] = [:]
    var failSet = false
    func refuseSaves() { failSet = true }
    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? { items["\(service)/\(account)"] }
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
        if failSet { throw .failed(status: -25308) }
        items["\(service)/\(account)"] = value
    }
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) { items["\(service)/\(account)"] = nil }
}

private actor Preferences: CloudRecognitionPreferencePort {
    var enabled = false
    var record: CloudRecognitionConsentRecord?
    func isEnabled() async -> Bool { enabled }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func consentRecord() async -> CloudRecognitionConsentRecord? { record }
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async { self.record = record }
}

private actor OffBar: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool { false }
    func setCaptureBarEnabled(_ enabled: Bool) {}
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

@MainActor private final class ConsentRecorder {
    var alerts: [NSAlert] = []
    var answers: [@MainActor (Bool) -> Void] = []
    var opened: [URL] = []
    func answer(_ agreed: Bool) { answers.removeFirst()(agreed) }
}

@MainActor private struct Fixture {
    let panel: SettingsPanelWindow
    let secrets: Secrets
    let preferences: Preferences
    let consent: ConsentRecorder

    func view<T: NSView>(_ id: String, as type: T.Type = NSView.self) throws -> T {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return try #require(panel.window.contentView.flatMap(find) as? T, "\(id)")
    }
    func click(_ id: String) throws {
        let control = try view(id, as: NSControl.self)
        if let toggle = control as? NSSwitch { toggle.state = toggle.state == .on ? .off : .on }
        control.sendAction(control.action, to: control.target)
    }
}

@MainActor private func fixture(_ locale: String? = nil) throws -> Fixture {
    let catalog = try locale.map(captureCatalog) ?? [:]
    let localize: (String) -> String = { catalog[$0] ?? $0 }
    let secrets = Secrets()
    let preferences = Preferences()
    let consent = ConsentRecorder()
    let model = CloudRecognitionSettingsModel(preferences: preferences, keys: BaiduCloudCredentialStore(secrets: secrets))
    let display = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
        defaults: UserDefaults(suiteName: "issue689-\(UUID().uuidString)")!,
        capturePreferences: OffBar(), captureLocalize: localize,
        cloudRecognition: CloudRecognitionSettingsEnvironment(model: model, presentConsent: { _, alert, answer in
            consent.alerts.append(alert)
            consent.answers.append(answer)
        }),
        openURL: { consent.opened.append($0) })
    panel.select(.capture)
    return Fixture(panel: panel, secrets: secrets, preferences: preferences, consent: consent)
}

private let zhHint = "云端识别会把要识别的那张图片上传到百度。只有在你点「识别文字」、同意过一次、并且这个开关打开时才会上传；在图片上直接选字永远只用本机识别。使用百度文字识别需要一个完成实名认证的百度账号，百度文档列出的证件只有中国大陆证件。百度会把上传的图片保存多久、在中国大陆以外能否使用这项服务，目前都未经确认。"
private let enHint = "Cloud Recognition uploads the image being recognized to Baidu. It uploads only when you click Recognize Text, have agreed once, and this switch is on; selecting text directly on an image always uses on-device recognition only. Baidu text recognition needs a Baidu account with real-name verification, and Baidu's documentation lists only mainland Chinese ID documents. How long Baidu keeps uploaded images, and whether the service works outside mainland China, are not confirmed."

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue689SettingsCloudGroupMatchesDesignWithoutKeys(_ locale: String) async throws {
    let f = try fixture(locale)
    defer { f.panel.window.close() }
    let zh = locale == "zh-Hans"
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    try await waitUntil { try f.view("settings.capture.ocr-pill", as: NSTextField.self).isHidden == false }
    #expect(toggle.state == .off)
    #expect(toggle.isEnabled)
    #expect(toggle.accessibilityLabel() == (zh ? "允许「识别文字」使用云端服务" : "Allow Recognize Text to use a cloud service"))
    #expect(try f.view("settings.capture.ocr-cloud.title", as: NSTextField.self).stringValue == toggle.accessibilityLabel())
    #expect(try f.view("settings.capture.ocr-pill", as: NSTextField.self).stringValue == (zh ? "未填写密钥" : "No Key"))
    let hint = try f.view("settings.capture.ocr-hint", as: NSTextField.self)
    #expect(hint.stringValue == (zh ? zhHint : enHint))
    #expect(hint.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: hint.frame.width, height: .greatestFiniteMagnitude)).height
            <= hint.frame.height + 0.5)
    #expect(try f.view("settings.capture.ocr-terms", as: NSButton.self).title == (zh ? "百度服务条款" : "Baidu Terms of Service"))
    let service = try f.view("settings.capture.ocr-service", as: NSPopUpButton.self)
    #expect(service.itemTitles == [zh ? "百度 OCR" : "Baidu OCR"])
    let api = try f.view("settings.capture.ocr-api-key", as: NSTextField.self)
    let secret = try f.view("settings.capture.ocr-secret-key", as: NSSecureTextField.self)
    #expect(!(api is NSSecureTextField))
    #expect(api.placeholderString == "API Key" && secret.placeholderString == "Secret Key")
    #expect(api.isEditable && secret.isEditable && !api.isHidden && !secret.isHidden)
    #expect(try f.view("settings.capture.ocr-save", as: NSButton.self).title == (zh ? "保存到钥匙串" : "Save to Keychain"))
    #expect(try f.view("settings.capture.ocr-keys-hint", as: NSTextField.self).stringValue
            == (zh ? "密钥存在钥匙串里。" : "Keys are stored in the keychain."))
    #expect(try f.view("settings.capture.ocr-fallback-hint", as: NSTextField.self).stringValue
            == (zh ? "没有密钥、离线或额度用完时改用本机识别，结果会标明用了哪个引擎。"
                   : "Without a key, offline, or when the quota is used up, Mado uses on-device recognition, and the result names the engine it used."))
    #expect(try f.view("settings.capture.ocr-remove", as: NSButton.self).isHidden)
    #expect(try f.view("settings.capture.ocr-saved-keys", as: NSTextField.self).isHidden)
    // The Capture Bar is off, and the group stays editable (owner 2026-11-13: 「文字识别不变灰」).
    let group = try f.view("settings.capture.ocr")
    #expect(!group.isHidden && group.alphaValue == 1)
    for id in ["settings.capture.ocr-cloud", "settings.capture.ocr-service", "settings.capture.ocr-api-key",
               "settings.capture.ocr-secret-key", "settings.capture.ocr-save", "settings.capture.ocr-terms"] {
        #expect(try f.view(id, as: NSControl.self).isEnabled, "\(id)")
    }
    // Nothing in the group overlaps, and it all sits inside the scrolled form.
    let form = try #require(group.superview)
    #expect(group.frame.minY >= 0 && group.frame.maxY <= form.frame.height)
    let visible = group.subviews.filter { !$0.isHidden && !($0 is NSBox) }
    for (index, a) in visible.enumerated() {
        for b in visible.dropFirst(index + 1) {
            #expect(!a.frame.intersects(b.frame), "\(a.accessibilityIdentifier()) overlaps \(b.accessibilityIdentifier())")
        }
        #expect(a.frame.minX >= 0 && a.frame.maxX <= group.frame.width + 0.5, "\(a.accessibilityIdentifier())")
    }
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue689SettingsSwitchNeedsSavedKeysThenConsent() async throws {
    let f = try fixture("zh-Hans")
    defer { f.panel.window.close() }
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    let message = try f.view("settings.capture.ocr-message", as: NSTextField.self)
    // No keys: the switch goes back off, says why, and asks nobody.
    try f.click("settings.capture.ocr-cloud")
    try await waitUntil { message.stringValue == "请先保存密钥。" }
    #expect(toggle.state == .off)
    #expect(f.consent.alerts.isEmpty)
    #expect(await f.preferences.enabled == false)

    // Blank keys are refused; nothing reaches the keychain.
    try f.view("settings.capture.ocr-api-key", as: NSTextField.self).stringValue = "  "
    try f.view("settings.capture.ocr-secret-key", as: NSSecureTextField.self).stringValue = "SK"
    try f.click("settings.capture.ocr-save")
    try await waitUntil { message.stringValue == "请填写 API Key 和 Secret Key。" }
    #expect(await f.secrets.items.isEmpty)

    // Saved keys show masked, with 移除密钥; the entry fields are cleared and hidden, the pill goes away.
    try f.view("settings.capture.ocr-api-key", as: NSTextField.self).stringValue = "AK1234567890"
    try f.view("settings.capture.ocr-secret-key", as: NSSecureTextField.self).stringValue = "SK-secret"
    try f.click("settings.capture.ocr-save")
    let saved = try f.view("settings.capture.ocr-saved-keys", as: NSTextField.self)
    try await waitUntil { !saved.isHidden }
    #expect(await f.secrets.items == ["io.github.anzchy.mado.cloud-recognition.baidu/api-key": "AK1234567890",
                                      "io.github.anzchy.mado.cloud-recognition.baidu/secret-key": "SK-secret"])
    #expect(saved.stringValue == "API Key ••••••••7890 · Secret Key ••••••••")
    #expect(!saved.stringValue.contains("SK-secret"))
    #expect(try f.view("settings.capture.ocr-remove", as: NSButton.self).isHidden == false)
    #expect(try f.view("settings.capture.ocr-remove", as: NSButton.self).title == "移除密钥")
    #expect(try f.view("settings.capture.ocr-api-key", as: NSTextField.self).isHidden)
    #expect(try f.view("settings.capture.ocr-api-key", as: NSTextField.self).stringValue.isEmpty)
    #expect(try f.view("settings.capture.ocr-secret-key", as: NSSecureTextField.self).stringValue.isEmpty)
    #expect(try f.view("settings.capture.ocr-pill", as: NSTextField.self).isHidden)
    #expect(message.stringValue.isEmpty)
    #expect(toggle.state == .off)

    // First turn-on asks; 取消 leaves it off and is remembered as declined.
    try f.click("settings.capture.ocr-cloud")
    try await waitUntil { f.consent.alerts.count == 1 }
    #expect(f.consent.alerts[0].buttons.map(\.title) == ["同意并打开", "取消"])
    f.consent.answer(false)
    try await waitUntil { await f.preferences.record?.granted == false }
    try await waitUntil { toggle.state == .off }
    #expect(await f.preferences.enabled == false)

    // Asked again; 同意并打开 turns it on and remembers the answer.
    try f.click("settings.capture.ocr-cloud")
    try await waitUntil { f.consent.alerts.count == 2 }
    f.consent.answer(true)
    try await waitUntil { await f.preferences.enabled }
    try await waitUntil { toggle.state == .on }
    #expect(await f.preferences.record?.granted == true)

    // Off and on again: no second question.
    try f.click("settings.capture.ocr-cloud")
    try await waitUntil { await f.preferences.enabled == false }
    try f.click("settings.capture.ocr-cloud")
    try await waitUntil { await f.preferences.enabled }
    #expect(f.consent.alerts.count == 2)
    #expect(toggle.state == .on)

    // 移除密钥 deletes both keys and turns the switch off.
    try f.click("settings.capture.ocr-remove")
    try await waitUntil { await f.secrets.items.isEmpty }
    try await waitUntil { toggle.state == .off }
    #expect(await f.preferences.enabled == false)
    #expect(try f.view("settings.capture.ocr-api-key", as: NSTextField.self).isHidden == false)
    #expect(try f.view("settings.capture.ocr-pill", as: NSTextField.self).isHidden == false)
    #expect(saved.isHidden)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue689SettingsKeychainFailureIsShown() async throws {
    let f = try fixture("en")
    defer { f.panel.window.close() }
    await f.secrets.refuseSaves()
    try f.view("settings.capture.ocr-api-key", as: NSTextField.self).stringValue = "AK"
    try f.view("settings.capture.ocr-secret-key", as: NSSecureTextField.self).stringValue = "SK"
    try f.click("settings.capture.ocr-save")
    let message = try f.view("settings.capture.ocr-message", as: NSTextField.self)
    try await waitUntil { message.stringValue == "The keys could not be saved to the keychain." }
    #expect(try f.view("settings.capture.ocr-saved-keys", as: NSTextField.self).isHidden)
    // The typed keys stay in the fields so the user can try again.
    #expect(try f.view("settings.capture.ocr-api-key", as: NSTextField.self).stringValue == "AK")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue689SettingsTermsLinkOpensBaiduTerms() async throws {
    let f = try fixture("zh-Hans")
    defer { f.panel.window.close() }
    try f.click("settings.capture.ocr-terms")
    #expect(f.consent.opened == [URL(string: "https://ai.baidu.com/ai-doc/REFERENCE/kk3dwjg7d")!])
    #expect(CloudRecognitionSettingsGroup.termsURL.absoluteString == "https://ai.baidu.com/ai-doc/REFERENCE/kk3dwjg7d")
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue689ConsentDialogNamesBaiduTheOneImageAndTheTerms(_ locale: String) throws {
    let catalog = try captureCatalog(locale)
    var opened: [URL] = []
    let alert = CloudRecognitionSettingsGroup.consentAlert(localize: { catalog[$0] ?? $0 }, openURL: { opened.append($0) })
    if locale == "zh-Hans" {
        #expect(alert.messageText == "要用百度识别文字吗？")
        #expect(alert.informativeText == "云端识别会把正在识别的那一张图片上传到百度，只在你选择「识别文字」时上传。在图片上直接选字永远只用本机识别。上传适用百度服务条款。")
        #expect(alert.buttons.map(\.title) == ["同意并打开", "取消"])
    } else {
        #expect(alert.messageText == "Use Baidu to recognize text?")
        #expect(alert.informativeText == "Cloud Recognition uploads the one image being recognized to Baidu, only when you choose Recognize Text. Selecting text directly on an image always uses on-device recognition. Baidu's terms of service apply to the upload.")
        #expect(alert.buttons.map(\.title) == ["Agree and Turn On", "Cancel"])
    }
    #expect(alert.alertStyle == .informational)
    let link = try #require(alert.accessoryView as? NSButton)
    #expect(link.title == (locale == "zh-Hans" ? "百度服务条款" : "Baidu Terms of Service"))
    link.sendAction(link.action, to: link.target)
    #expect(opened == [CloudRecognitionSettingsGroup.termsURL])
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue689SettingsReadsSavedStateOnOpen() async throws {
    let secrets = Secrets()
    let preferences = Preferences()
    let model = CloudRecognitionSettingsModel(preferences: preferences, keys: BaiduCloudCredentialStore(secrets: secrets))
    try await model.saveKeys(apiKey: "AK1234567890", secretKey: "SK")
    _ = await model.answerConsent(granted: true)
    let display = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
        defaults: UserDefaults(suiteName: "issue689-\(UUID().uuidString)")!, capturePreferences: OffBar(),
        cloudRecognition: CloudRecognitionSettingsEnvironment(model: model, presentConsent: { _, _, _ in }))
    defer { panel.window.close() }
    panel.select(.capture)
    let f = Fixture(panel: panel, secrets: secrets, preferences: preferences, consent: ConsentRecorder())
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    try await waitUntil { toggle.state == .on }
    #expect(try f.view("settings.capture.ocr-saved-keys", as: NSTextField.self).stringValue == "API Key ••••••••7890 · Secret Key ••••••••")
    #expect(try f.view("settings.capture.ocr-pill", as: NSTextField.self).isHidden)
}
