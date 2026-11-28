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

private actor OnBar: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool { true }
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

@MainActor private func fixture(_ locale: String? = nil, captureBarOn: Bool = false) throws -> Fixture {
    let catalog = try locale.map(captureCatalog) ?? [:]
    let localize: (String) -> String = { catalog[$0] ?? $0 }
    let secrets = Secrets()
    let preferences = Preferences()
    let consent = ConsentRecorder()
    let model = CloudRecognitionSettingsModel(preferences: preferences, keys: BaiduCloudCredentialStore(secrets: secrets))
    let display = InMemoryDisplayPreferencesStore()
    let bar: any CaptureBarPreferencePort
    if captureBarOn { bar = OnBar() } else { bar = OffBar() }
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
        defaults: UserDefaults(suiteName: "issue689-\(UUID().uuidString)")!,
        capturePreferences: bar, captureLocalize: localize,
        cloudRecognition: CloudRecognitionSettingsEnvironment(model: model, presentConsent: { _, alert, answer in
            consent.alerts.append(alert)
            consent.answers.append(answer)
        }),
        openURL: { consent.opened.append($0) })
    panel.select(.capture)
    return Fixture(panel: panel, secrets: secrets, preferences: preferences, consent: consent)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue886CloudTabLoopKeepsRestoreBeforeSwitch(_ locale: String) async throws {
    let f = try fixture(locale, captureBarOn: true)
    defer { f.panel.window.close() }
    let shortcut = try f.view("settings.capture.shortcut-4", as: NSControl.self)
    let restore = try f.view("settings.capture.shortcut-restore", as: NSButton.self)
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    let service = try f.view("settings.capture.ocr-service", as: NSPopUpButton.self)
    try await waitUntil { shortcut.isEnabled && restore.isEnabled }
    let window = f.panel.window
    window.recalculateKeyViewLoop()
    f.panel.select(.capture)
    #expect(shortcut.nextKeyView === restore)
    #expect(restore.nextKeyView === toggle)
    #expect(toggle.nextKeyView === service)
    var current: NSView = shortcut
    for expected in [restore as NSView, toggle, service] {
        current = try #require(current.nextValidKeyView)
        #expect(current === expected)
    }
}

private let zhHint = "云识别只会把你要识别的那张图片发送到你配置的服务。只有在你点「识别文字」或「识别表格」、对该服务主机同意过一次、并且「云识别」开关打开时才会发送；在图片上直接选字永远只用本机识别。百度文字识别需要完成实名认证的百度账号，百度文档只列出中国大陆证件。百度保存图片的期限及在中国大陆以外能否使用，尚未确认。"
private let enHint = "Cloud Recognition sends only the image you ask to recognise to the service you configured. It sends only when you click Recognise Text or Recognise Table, have agreed once for that service host, and the Cloud Recognition switch is on. Selecting text directly on an image always uses on-device recognition. Baidu text recognition requires a Baidu account with real-name verification; its documentation lists only mainland Chinese ID documents. How long Baidu keeps images and whether its service works outside mainland China are unconfirmed."
private let zhCloudGroupHint = "只在你点「识别文字」或「识别表格」时，才把那张图片发送出去；在图片上选字只用本机。"
private let enCloudGroupHint = "Only when you click Recognise Text or Recognise Table is that image sent; selecting text on an image uses only on-device recognition."

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue886CloudCatalogHasNoOrphanAllowKey(_ locale: String) throws {
    let catalog = try captureCatalog(locale)
    #expect(catalog["Allow Cloud Recognition"] == nil)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue886CloudIsFirstLevelBeforeEditableTextAndTable(_ locale: String) async throws {
    let f = try fixture(locale)
    defer { f.panel.window.close() }
    let cloud = try f.view("settings.capture.cloud")
    let text = try f.view("settings.capture.ocr")
    let table = try f.view("settings.capture.table")
    let form = try #require(cloud.superview)
    #expect(text.superview === form && table.superview === form)
    #expect(abs(cloud.frame.minY - text.frame.maxY) < 0.5)
    #expect(abs(text.frame.minY - table.frame.maxY) < 0.5)
    let heading = try f.view("settings.capture.cloud-heading", as: NSTextField.self)
    #expect(heading.stringValue == (locale == "zh-Hans" ? "云识别" : "Cloud Recognition"))
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    let pill = try f.view("settings.capture.ocr-pill")
    try await waitUntil { !pill.isHidden }
    let caption = try f.view("settings.capture.ocr-cloud.title", as: NSTextField.self)
    if locale == "zh-Hans" {
        #expect(abs(pill.frame.midY - toggle.frame.midY) < 4, "Chinese status stays on the switch row")
        #expect(pill.frame.minX >= caption.frame.maxX + 4, "Chinese status follows the caption")
    } else {
        #expect(pill.frame.minY >= toggle.frame.maxY + 10, "English status follows the wrapped caption")
    }
    let hint = try f.view("settings.capture.cloud-hint", as: NSTextField.self)
    let learn = try f.view("settings.capture.cloud-learn", as: NSButton.self)
    #expect(toggle.superview === cloud && pill.superview === cloud && hint.superview === cloud && learn.superview === cloud)
    #expect(learn.title == (locale == "zh-Hans" ? "了解更多 ↗" : "Learn More ↗"))
    #expect(hint.stringValue == (locale == "zh-Hans" ? zhCloudGroupHint : enCloudGroupHint))
    #expect(hint.maximumNumberOfLines == 2)
    #expect(hint.frame.maxX + 8 <= learn.frame.minX + 0.5)
    #expect(abs(hint.frame.minY - learn.frame.minY) < 0.5)
    let oneLine = hint.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: CGFloat.greatestFiniteMagnitude)).height.rounded(.up)
    #expect(hint.frame.height <= oneLine * 2 + 2, "hint must reserve at most two lines")
    expectLayoutFits(layoutLabelMeasure(hint.stringValue, font: hint.font!, frame: hint.frame.size),
                     view: hint, shown: hint.stringValue, locale: locale, test: "i886-fix1-cloud-hint")
    #expect(try f.view("settings.capture.ocr-service").superview === text)
    #expect(try f.view("settings.capture.ocr-api-key").superview === text)
    #expect(try f.view("settings.capture.table-service").superview === table)
    #expect(toggle.state == .off && toggle.isEnabled)
    for id in ["settings.capture.ocr-service", "settings.capture.ocr-api-key", "settings.capture.ocr-secret-key",
               "settings.capture.ocr-save", "settings.capture.table-service"] {
        #expect(try f.view(id, as: NSControl.self).isEnabled, "\(id) remains editable with cloud off")
    }
    let restore = try f.view("settings.capture.shortcut-restore")
    #expect(cloud.frame.maxY < restore.frame.minY)
    #expect(restore.nextKeyView === toggle)
    let service = try f.view("settings.capture.ocr-service")
    #expect(toggle.nextKeyView === service)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue689SettingsCloudGroupMatchesDesignWithoutKeys(_ locale: String) async throws {
    let f = try fixture(locale)
    defer { f.panel.window.close() }
    let zh = locale == "zh-Hans"
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    try await waitUntil { try f.view("settings.capture.ocr-pill", as: NSTextField.self).isHidden == false }
    #expect(toggle.state == .off)
    #expect(toggle.isEnabled)
    #expect(toggle.accessibilityLabel() == (zh ? "允许云识别（识别文字、识别表格）" : "Allow Cloud Recognition (Recognise Text, Recognise Table)"))
    #expect(try f.view("settings.capture.ocr-cloud.title", as: NSTextField.self).stringValue == toggle.accessibilityLabel())
    #expect(try f.view("settings.capture.ocr-pill", as: NSTextField.self).stringValue == (zh ? "未填写访问密钥" : "No Access Key"))
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
            == (zh ? "访问密钥保存在 macOS 钥匙串中。" : "Keys are stored in the macOS Keychain."))
    #expect(try f.view("settings.capture.ocr-fallback-hint", as: NSTextField.self).stringValue
            == (zh ? "没有访问密钥、离线或额度用完时，「识别文字」会改用本机识别并标明；「识别表格」只能用云识别。"
                   : "Without an access key, offline, or when the quota is used up, Recognise Text falls back to on-device recognition and says so; Recognise Table needs Cloud Recognition."))
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
    try await waitUntil { message.stringValue == "请先保存访问密钥。" }
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
    #expect(try f.view("settings.capture.ocr-remove", as: NSButton.self).title == "移除访问密钥")
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
    try await waitUntil { message.stringValue == "The access keys could not be saved to the macOS Keychain." }
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
    #expect(!alert.informativeText.hasPrefix(alert.messageText), "Consent body must not repeat its title in \(locale)")
    if locale == "zh-Hans" {
        #expect(alert.messageText == "要用百度识别文字吗？")
        #expect(alert.informativeText == "只有你同意向这个服务主机上传并选择「识别文字」后，才会把你要识别的那张图片发送给百度。在图片上直接选字永远只用本机识别。上传适用百度服务条款。百度文字识别需要完成实名认证的百度账号，百度文档只列出中国大陆证件。百度保存图片的期限及在中国大陆以外能否使用，尚未确认。")
        #expect(alert.buttons.map(\.title) == ["同意并打开", "取消"])
    } else {
        #expect(alert.messageText == "Use Baidu to recognise text?")
        #expect(alert.informativeText == "Only the image you ask to recognise is sent to Baidu after you agree for this service host and choose Recognise Text. Selecting text directly on an image always uses on-device recognition only. Baidu’s terms apply. Baidu text recognition needs a Baidu account with real-name verification; its documentation lists only mainland Chinese ID documents. How long Baidu keeps images and whether its service works outside mainland China are unconfirmed.")
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

// #832 EXT-04 (spec #830, grilling 20261122 decision 7): the group names the Baidu product to enable, one static
// sentence in the UI language, shown whatever the switch and key state, as plain text (no link, no new control).
private let zhProduct = "需在百度智能云控制台为你的应用开通「通用文字识别」。"
private let enProduct = "Enable “General Text Recognition” for your app in the Baidu AI Cloud console."

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"], [false, true])
func issue832SettingsNamesTheBaiduProductToEnable(_ locale: String, keyedAndOn: Bool) async throws {
    let catalog = try captureCatalog(locale)
    let secrets = Secrets()
    let preferences = Preferences()
    let model = CloudRecognitionSettingsModel(preferences: preferences, keys: BaiduCloudCredentialStore(secrets: secrets))
    if keyedAndOn {
        try await model.saveKeys(apiKey: "AKAKAKAKWWMW", secretKey: "SK")
        _ = await model.answerConsent(granted: true)
    }
    let display = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
        defaults: UserDefaults(suiteName: "issue832-\(UUID().uuidString)")!, capturePreferences: OffBar(),
        captureLocalize: { catalog[$0] ?? $0 },
        cloudRecognition: CloudRecognitionSettingsEnvironment(model: model, presentConsent: { _, _, _ in }),
        openURL: { _ in })
    defer { panel.window.close() }
    panel.select(.capture)
    let f = Fixture(panel: panel, secrets: secrets, preferences: preferences, consent: ConsentRecorder())
    let toggle = try f.view("settings.capture.ocr-cloud", as: NSSwitch.self)
    if keyedAndOn {
        try await waitUntil { toggle.state == .on }
    } else {
        try await waitUntil { try f.view("settings.capture.ocr-pill", as: NSTextField.self).isHidden == false }
        #expect(toggle.state == .off)
    }
    let sentence = try f.view("settings.capture.ocr-product-hint", as: NSTextField.self)
    #expect(sentence.stringValue == (locale == "zh-Hans" ? zhProduct : enProduct))
    #expect(!sentence.isHidden && sentence.alphaValue == 1)
    // Plain, static text: not editable, not selectable, no link attribute, nothing to press or focus.
    #expect(!sentence.isEditable && !sentence.isSelectable && !sentence.acceptsFirstResponder)
    #expect(!sentence.attributedStringValue.string.contains("http"))
    var linked = false
    sentence.attributedStringValue.enumerateAttribute(.link, in: NSRange(location: 0, length: sentence.attributedStringValue.length)) { value, _, _ in
        if value != nil { linked = true }
    }
    #expect(!linked)
    // Whole, inside the group, under the 服务 row and above the 密钥 row, overlapping nothing.
    #expect(sentence.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: sentence.frame.width, height: .greatestFiniteMagnitude)).height
            <= sentence.frame.height + 0.5)
    let group = try f.view("settings.capture.ocr")
    #expect(sentence.superview === group)
    #expect(sentence.frame.minX >= 0 && sentence.frame.maxX <= group.frame.width + 0.5)
    let service = try f.view("settings.capture.ocr-service", as: NSPopUpButton.self)
    // The 密钥 row starts at the API Key field's top in both states (the masked line sits on the same row).
    let keysRowTop = try f.view("settings.capture.ocr-api-key").frame.minY
    #expect(sentence.frame.minY >= service.frame.maxY && sentence.frame.maxY <= keysRowTop)
    for other in group.subviews where other !== sentence && !other.isHidden && !(other is NSBox) {
        #expect(!sentence.frame.intersects(other.frame), "overlaps \(other.accessibilityIdentifier())")
    }
    #expect(try f.view("settings.capture.ocr-fallback-hint").frame.maxY <= group.frame.height)
}
