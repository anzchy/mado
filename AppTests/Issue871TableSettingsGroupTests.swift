import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #871 WI-5: Settings › 截图 › 表格识别 (state 35 `settings.html?section=capture&scroll=table&case=…`). The group sits
// after 文字识别 with no switch of its own; key per configuration, the real host, the Test of the built-in sample
// with one plain line per result, Advanced (address, model), Custom, and the consent dialog per host.

private actor Secrets871App: CloudSecretStorePort {
    var items: [String: String] = [:]
    /// Removal fails as SecItemDelete can (any status but success or not-found).
    var removalFails = false
    func failRemoval() { removalFails = true }
    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? { items["\(service)/\(account)"] }
    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
        items["\(service)/\(account)"] = value
    }
    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) {
        if removalFails { throw .failed(status: -25308) }
        items["\(service)/\(account)"] = nil
    }
}

private actor Cloud871App: CloudRecognitionPreferencePort {
    var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func isEnabled() async -> Bool { enabled }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func consentRecord() async -> CloudRecognitionConsentRecord? { nil }
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async {}
}

private actor Table871App: TableRecognitionPreferencePort {
    var stored = TableRecognitionStoredSettings.defaults
    var consents: [String: Bool]
    init(consents: [String: Bool]) { self.consents = consents }
    /// Holds the next read of the stored settings until `releaseRead()`; it then returns what is stored by then.
    private var holdNextRead = false
    private var heldRead: CheckedContinuation<Void, Never>?
    func holdRead() { holdNextRead = true }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    var readWaiting: Bool { heldRead != nil }
    func storedSettings() async -> TableRecognitionStoredSettings {
        if holdNextRead {
            holdNextRead = false
            await withCheckedContinuation { heldRead = $0 }
        }
        return stored
    }
    func setStoredSettings(_ settings: TableRecognitionStoredSettings) async { stored = settings }
    func consent(forHost host: String) async -> Bool? { consents[host] }
    func setConsent(_ granted: Bool?, forHost host: String) async { consents[host] = granted }
}

/// Answers from a queue (the sample table when empty); optionally holds each call until `open()`.
private actor Transport871App: HTTPTransport {
    var replies: [Result<HTTPResponse, URLError>] = []
    private(set) var requests: [URLRequest] = []
    var gated = false
    private var gate: CheckedContinuation<Void, Never>?
    func queue(_ reply: Result<HTTPResponse, URLError>) { replies.append(reply) }
    func hold() { gated = true }
    func open() { gated = false; gate?.resume(); gate = nil }
    var waiting: Bool { gate != nil }
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        requests.append(request)
        if gated { await withCheckedContinuation { gate = $0 } }
        let reply = replies.isEmpty ? .success(sample871App()) : replies.removeFirst()
        return try reply.get()
    }
}

private func sample871App() -> HTTPResponse {
    let content = "| Item | Qty | Price |\n|---|---|---|\n| Apple | 3 | 1.20 |\n| Pear | 5 | 0.80 |"
    let body = try! JSONSerialization.data(withJSONObject: ["choices": [[
        "index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]])
    return HTTPResponse(statusCode: 200, body: body)
}

private actor OffBar871: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool { false }
    func setCaptureBarEnabled(_ enabled: Bool) {}
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

@MainActor private final class Dialogs871 {
    var alerts: [NSAlert] = []
    var answers: [@MainActor (Bool) -> Void] = []
    var opened: [URL] = []
    func answer(_ agreed: Bool) { answers.removeFirst()(agreed) }
}

@MainActor private struct Fixture871App {
    let panel: SettingsPanelWindow
    let secrets: Secrets871App
    let table: Table871App
    let transport: Transport871App
    let dialogs: Dialogs871

    func view<T: NSView>(_ id: String, as type: T.Type = NSView.self) throws -> T {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return try #require(panel.window.contentView.flatMap(find) as? T, "\(id)")
    }
    func text(_ id: String) throws -> String { try view(id, as: NSTextField.self).stringValue }
    func shown(_ id: String) throws -> Bool { try !view(id).isHidden }
    func click(_ id: String) throws {
        let control = try view(id, as: NSControl.self)
        control.sendAction(control.action, to: control.target)
    }
    func saveKey(_ key: String) async throws {
        try view("settings.capture.table-key", as: NSSecureTextField.self).stringValue = key
        try click("settings.capture.table-save")
        try await waitUntil { try shown("settings.capture.table-saved-key") }
    }
}

@MainActor private func fixture871App(_ locale: String = "zh-Hans", enabled: Bool = true,
                                      consents: [String: Bool] = ["api.deepseek.com": true]) throws -> Fixture871App {
    let catalog = try captureCatalog(locale)
    let localize: (String) -> String = { catalog[$0] ?? $0 }
    let secrets = Secrets871App()
    let table = Table871App(consents: consents)
    let transport = Transport871App()
    let dialogs = Dialogs871()
    let model = TableRecognitionSettingsModel(cloud: Cloud871App(enabled: enabled), preferences: table,
                                              keys: TableRecognitionKeyStore(secrets: secrets), transport: transport)
    let display = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
        defaults: UserDefaults(suiteName: "issue871-\(UUID().uuidString)")!,
        capturePreferences: OffBar871(), captureLocalize: localize,
        tableRecognition: TableRecognitionSettingsEnvironment(model: model, presentConsent: { _, alert, answer in
            dialogs.alerts.append(alert)
            dialogs.answers.append(answer)
        }),
        openURL: { dialogs.opened.append($0) })
    panel.select(.capture)
    return Fixture871App(panel: panel, secrets: secrets, table: table, transport: transport, dialogs: dialogs)
}

private let zhTestNote = "发送内置示例，不发送你的图片；可能收费。"

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5GroupFollowsTextRecognitionWithoutASwitch() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    let group = try f.view("settings.capture.table")
    let ocr = try f.view("settings.capture.ocr")
    let form = try #require(group.superview)
    #expect(group.superview === ocr.superview)
    // The form is not flipped: 表格识别 is directly under 文字识别 and inside the form.
    #expect(abs(group.frame.maxY - ocr.frame.minY) < 0.5)
    #expect(group.frame.minY >= 0 && group.frame.maxY <= form.frame.height)
    func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
    #expect(!all(group).contains { $0 is NSSwitch }, "no 云识别 switch of its own")
    #expect(all(group).contains { ($0 as? NSTextField)?.stringValue == "表格识别" })
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue871WI5DefaultCaseMatchesState35(_ locale: String) async throws {
    let f = try fixture871App(locale, enabled: false)
    defer { f.panel.window.close() }
    let zh = locale == "zh-Hans"
    try await waitUntil { try f.text("settings.capture.table-host") == "api.deepseek.com" }
    let service = try f.view("settings.capture.table-service", as: NSPopUpButton.self)
    #expect(service.itemTitles == ["DeepSeek", zh ? "自定义" : "Custom"])
    #expect(service.titleOfSelectedItem == "DeepSeek")
    #expect(try f.text("settings.capture.table-label-key") == (zh ? "访问密钥" : "Access Key"))
    #expect(try f.text("settings.capture.table-label-host") == (zh ? "图片发送到" : "Images Sent To"))
    let key = try f.view("settings.capture.table-key", as: NSSecureTextField.self)
    #expect(key.placeholderString == (zh ? "粘贴访问密钥（API Key）" : "Paste the access key (API Key)"))
    #expect(try f.view("settings.capture.table-save", as: NSButton.self).title == (zh ? "保存到钥匙串" : "Save to Keychain"))
    #expect(try f.text("settings.capture.table-key-hint") == (zh ? "还没有密钥？" : "No key yet?"))
    #expect(try f.view("settings.capture.table-key-help", as: NSButton.self).title == (zh ? "怎么获取 ↗" : "How to Get One ↗"))
    #expect(try f.text("settings.capture.table-host-hint")
            == (zh ? "只在你点「识别表格」后，图片才发送到这里。" : "Images are sent here only after you click Recognise Table."))
    #expect(try f.view("settings.capture.table-privacy", as: NSButton.self).title == (zh ? "隐私说明 ↗" : "Privacy ↗"))
    let test = try f.view("settings.capture.table-test", as: NSButton.self)
    #expect(test.title == (zh ? "测试" : "Test") && !test.isEnabled)
    #expect(try f.text("settings.capture.table-test-hint")
            == (zh ? zhTestNote + "填写并保存密钥后可测试。"
                   : "Sends a built-in sample, not your images; may be charged. Save a key to test."))
    #expect(try f.text("settings.capture.table-test-status").isEmpty)
    #expect(try f.text("settings.capture.table-advanced-title") == (zh ? "高级" : "Advanced"))
    #expect(try !f.shown("settings.capture.table-address") && !f.shown("settings.capture.table-model"))
    #expect(try f.text("settings.capture.table-cost")
            == (zh ? "可能使用服务账户的余额，费用请到该服务查看。" : "May use your service account's balance; check the service for charges."))
    #expect(try f.view("settings.capture.table-cost-link", as: NSButton.self).title == (zh ? "了解更多 ↗" : "Learn More ↗"))
    // The global switch is off, and every row stays editable (#886 decision).
    for id in ["settings.capture.table-service", "settings.capture.table-key", "settings.capture.table-save",
               "settings.capture.table-key-help", "settings.capture.table-privacy", "settings.capture.table-advanced"] {
        #expect(try f.view(id, as: NSControl.self).isEnabled, "\(id)")
    }
    // Visible rows do not overlap and stay inside the group.
    let group = try f.view("settings.capture.table")
    let visible = group.subviews.filter { !$0.isHidden && !($0 is NSBox) }
    for (index, a) in visible.enumerated() {
        for b in visible.dropFirst(index + 1) {
            #expect(!a.frame.intersects(b.frame), "\(a.accessibilityIdentifier()) overlaps \(b.accessibilityIdentifier())")
        }
        #expect(a.frame.minX >= 0 && a.frame.maxX <= group.frame.width + 0.5, "\(a.accessibilityIdentifier())")
        #expect(a.frame.maxY <= group.frame.height + 0.5, "\(a.accessibilityIdentifier())")
    }
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5LinksOpenTheHelpSite() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try f.click("settings.capture.table-key-help")
    try f.click("settings.capture.table-privacy")
    try f.click("settings.capture.table-cost-link")
    #expect(f.dialogs.opened.map(\.absoluteString) == ["https://anzchy.github.io/mado/deepseek-key.html",
                                                       "https://anzchy.github.io/mado/cloud-recognition.html",
                                                       "https://anzchy.github.io/mado/deepseek-key.html"])
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5SavedCaseShowsTheMaskedKeyReplaceAndRemove() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    #expect(try f.text("settings.capture.table-saved-key") == "••••••••••••3f9a")
    #expect(try f.text("settings.capture.table-key-pill") == "已保存到钥匙串")
    #expect(try f.view("settings.capture.table-replace", as: NSButton.self).title == "更换…")
    #expect(try f.view("settings.capture.table-remove", as: NSButton.self).title == "移除")
    #expect(try !f.shown("settings.capture.table-key") && !f.shown("settings.capture.table-save"))
    #expect(try f.view("settings.capture.table-key", as: NSSecureTextField.self).stringValue.isEmpty)
    #expect(try f.view("settings.capture.table-test", as: NSButton.self).isEnabled)
    #expect(try f.text("settings.capture.table-test-hint") == zhTestNote)
    #expect(await f.secrets.items.values.contains("sk-live-00003f9a"))
    // 更换… shows the field again; saving replaces the key.
    try f.click("settings.capture.table-replace")
    #expect(try f.shown("settings.capture.table-key"))
    try await f.saveKey("sk-live-0000beef")
    #expect(try f.text("settings.capture.table-saved-key") == "••••••••••••beef")
    // 移除 deletes it.
    try f.click("settings.capture.table-remove")
    try await waitUntil { try f.shown("settings.capture.table-key") }
    #expect(await f.secrets.items.isEmpty)
    // An empty key is refused with one line.
    try f.click("settings.capture.table-save")
    try await waitUntil { try f.text("settings.capture.table-key-message") == "请填写访问密钥。" }
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [
    ("ok", "✓ 测试成功，可以识别示例表格。"),
    ("key", "⚠ 密钥不被接受，请更换密钥。"),
    ("address", "⚠ 无法连接这个地址，请检查「高级」里的地址。"),
    ("model", "⚠ 这个模型不支持图片，请换一个模型。"),
    ("offline", "⚠ 无法联网，请检查网络后重试。"),
    ("quota", "⚠ 额度不足，请到服务账户检查。"),
    ("unknown", "⚠ 测试未通过。"),
])
func issue871WI5TestResultsInPlainWords(_ testCase: String, _ line: String) async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    let reply: Result<HTTPResponse, URLError>? = switch testCase {
    case "key": .success(HTTPResponse(statusCode: 401, body: Data()))
    case "address": .failure(URLError(.cannotFindHost))
    case "model": .success(HTTPResponse(statusCode: 400, body: Data(#"{"error":{"message":"This model does not support image input"}}"#.utf8)))
    case "offline": .failure(URLError(.notConnectedToInternet))
    case "quota": .success(HTTPResponse(statusCode: 402, body: Data()))
    case "unknown": .success(HTTPResponse(statusCode: 500, body: Data()))
    default: nil
    }
    if let reply { await f.transport.queue(reply) }
    try f.click("settings.capture.table-test")
    try await waitUntil { try f.text("settings.capture.table-test-status") == line }
    #expect(await f.transport.requests.count == 1)
    #expect(try f.view("settings.capture.table-test", as: NSButton.self).title == "测试")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5TestingCaseShowsCancelAndCancelSendsNoResult() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    await f.transport.hold()
    try f.click("settings.capture.table-test")
    try await waitUntil { await f.transport.waiting }
    let test = try f.view("settings.capture.table-test", as: NSButton.self)
    #expect(test.title == "取消" && test.isEnabled)
    #expect(try f.text("settings.capture.table-test-status") == "正在测试…")
    #expect(try f.shown("settings.capture.table-test-spinner"))
    try f.click("settings.capture.table-test")
    await f.transport.open()
    try await waitUntil { test.title == "测试" }
    #expect(try f.text("settings.capture.table-test-status").isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5AdvancedShowsAddressAndModelAndModelChangeClearsTheResult() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    try f.click("settings.capture.table-test")
    try await waitUntil { try f.text("settings.capture.table-test-status") == "✓ 测试成功，可以识别示例表格。" }
    let advanced = try f.view("settings.capture.table-advanced", as: NSButton.self)
    advanced.state = .on
    try f.click("settings.capture.table-advanced")
    #expect(try f.shown("settings.capture.table-address") && f.shown("settings.capture.table-model"))
    #expect(try f.text("settings.capture.table-address") == "https://api.deepseek.com")
    #expect(try f.text("settings.capture.table-model") == "deepseek-flash")
    #expect(try f.text("settings.capture.table-address-hint") == "换地址会移除已保存的密钥，需要重新保存并同意。")
    #expect(try f.text("settings.capture.table-model-hint") == "改模型后请重新测试。")
    let model = try f.view("settings.capture.table-model", as: NSTextField.self)
    model.stringValue = "deepseek-vision"
    try f.click("settings.capture.table-model")
    try await waitUntil { try f.text("settings.capture.table-test-status").isEmpty }
    #expect(await f.table.stored.deepSeekModel == "deepseek-vision")
    // A new address: the key does not carry over, the old host's consent is gone.
    let address = try f.view("settings.capture.table-address", as: NSTextField.self)
    address.stringValue = "https://gw.example.com/v1"
    try f.click("settings.capture.table-address")
    try await waitUntil { try f.text("settings.capture.table-host") == "gw.example.com" }
    #expect(try f.shown("settings.capture.table-key"))
    #expect(await f.table.consents["api.deepseek.com"] == nil)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5CustomOpensAdvancedAndNeedsBoth() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    let service = try f.view("settings.capture.table-service", as: NSPopUpButton.self)
    service.selectItem(at: 1)
    try f.click("settings.capture.table-service")
    try await waitUntil { try f.text("settings.capture.table-host") == "（先填写地址）" }
    #expect(try f.shown("settings.capture.table-address") && f.shown("settings.capture.table-model"))
    #expect(try f.text("settings.capture.table-address").isEmpty && f.text("settings.capture.table-model").isEmpty)
    #expect(try f.view("settings.capture.table-address", as: NSTextField.self).placeholderString
            == "https://…（必填，需要 OpenAI 兼容）")
    #expect(try f.view("settings.capture.table-model", as: NSTextField.self).placeholderString == "模型名称（必须能读图片）")
    #expect(try f.text("settings.capture.table-address-hint") == "自定义服务必须填写地址和模型。")
    #expect(try !f.shown("settings.capture.table-key-help") && !f.shown("settings.capture.table-key-hint"))
    #expect(try !f.view("settings.capture.table-test", as: NSButton.self).isEnabled)
    // Advanced stays open while Custom needs it.
    let advanced = try f.view("settings.capture.table-advanced", as: NSButton.self)
    advanced.state = .off
    try f.click("settings.capture.table-advanced")
    #expect(try f.shown("settings.capture.table-address"))
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5TestAsksConsentNamingTheHost() async throws {
    let f = try fixture871App(consents: [:])
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    try f.click("settings.capture.table-test")
    try await waitUntil { f.dialogs.alerts.count == 1 }
    #expect(f.dialogs.alerts[0].messageText == "将图片发送到 api.deepseek.com 识别表格？")
    #expect(f.dialogs.alerts[0].buttons.map(\.title) == ["同意并测试", "取消"])
    #expect(await f.transport.requests.isEmpty)
    f.dialogs.answer(false)
    try await waitUntil { try f.view("settings.capture.table-test", as: NSButton.self).title == "测试" }
    #expect(await f.transport.requests.isEmpty)
    #expect(await f.table.consents.isEmpty)
    try f.click("settings.capture.table-test")
    try await waitUntil { f.dialogs.alerts.count == 2 }
    f.dialogs.answer(true)
    try await waitUntil { try f.text("settings.capture.table-test-status") == "✓ 测试成功，可以识别示例表格。" }
    #expect(await f.table.consents == ["api.deepseek.com": true])
    #expect(await f.transport.requests.count == 1)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871WI5SwitchOffTestSaysSoAndSendsNothing() async throws {
    let f = try fixture871App(enabled: false)
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    try f.click("settings.capture.table-test")
    try await waitUntil { try f.text("settings.capture.table-test-status") == "⚠ 云识别已关闭，没有发送。" }
    #expect(await f.transport.requests.isEmpty)
}

// MARK: - Fix round 1

/// The shown leaves of the group (controls and plain views), with frames in the group's coordinates.
@MainActor private func shownLeaves871(_ root: NSView) -> [(view: NSView, frame: NSRect)] {
    var leaves: [(NSView, NSRect)] = []
    func walk(_ view: NSView) {
        for child in view.subviews where !child.isHidden && !(child is NSBox) {
            if child is NSControl || child.subviews.allSatisfy(\.isHidden) {
                leaves.append((child, child.convert(child.bounds, to: root)))
            } else {
                walk(child)
            }
        }
    }
    walk(root)
    return leaves
}

/// Whether a label's text needs more room than its frame (or its line limit) gives it.
@MainActor private func clipped871(_ field: NSTextField) -> Bool {
    guard !field.stringValue.isEmpty, !field.isEditable else { return false }
    let needed = field.attributedStringValue.boundingRect(
        with: NSSize(width: field.frame.width - 4, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up)
    let font = field.font ?? DesignMetrics.font("uiSmall")
    let line = (font.ascender - font.descender + font.leading).rounded(.up)
    let lines = Int((needed / line).rounded())
    return needed > field.frame.height + 0.5 || (field.maximumNumberOfLines > 0 && lines > field.maximumNumberOfLines)
}

/// Every shown control fits inside the group, no two overlap, and no text is cut off.
@MainActor private func expectFitsAndApart871(_ f: Fixture871App, _ label: String) throws {
    let group = try f.view("settings.capture.table")
    let leaves = shownLeaves871(group)
    for (index, a) in leaves.enumerated() {
        let id = a.view.accessibilityIdentifier()
        #expect(a.frame.minX >= -0.5 && a.frame.maxX <= group.frame.width + 0.5, "\(label): \(id) leaves the row")
        #expect(a.frame.minY >= -0.5 && a.frame.maxY <= group.frame.height + 0.5, "\(label): \(id) leaves the group")
        if let field = a.view as? NSTextField {
            #expect(!clipped871(field), "\(label): \(id) is cut off: \(field.stringValue)")
        }
        for b in leaves.dropFirst(index + 1) {
            #expect(!a.frame.intersects(b.frame), "\(label): \(id) overlaps \(b.view.accessibilityIdentifier())")
        }
    }
}

private func reply871(_ testCase: String) -> Result<HTTPResponse, URLError>? {
    switch testCase {
    case "key": .success(HTTPResponse(statusCode: 401, body: Data()))
    case "address": .failure(URLError(.cannotFindHost))
    case "model": .success(HTTPResponse(statusCode: 400, body: Data(#"{"error":{"message":"This model does not support image input"}}"#.utf8)))
    case "offline": .failure(URLError(.notConnectedToInternet))
    case "quota": .success(HTTPResponse(statusCode: 402, body: Data()))
    case "unknown": .success(HTTPResponse(statusCode: 500, body: Data()))
    default: nil
    }
}

private let state35Cases871 = ["default", "saved", "testing", "ok", "key", "address", "model", "offline", "quota",
                               "unknown", "off", "advanced", "custom"]

@MainActor @Test(.timeLimit(.minutes(5)), arguments: ["en", "zh-Hans"])
func issue871Fix1EveryCaseFitsWithoutOverlapInBothLanguages(_ locale: String) async throws {
    for testCase in state35Cases871 {
        let f = try fixture871App(locale, enabled: testCase != "off")
        defer { f.panel.window.close() }
        try await waitUntil { try !f.text("settings.capture.table-host").isEmpty }
        switch testCase {
        case "default":
            break
        case "advanced":
            let advanced = try f.view("settings.capture.table-advanced", as: NSButton.self)
            advanced.state = .on
            try f.click("settings.capture.table-advanced")
        case "custom":
            let service = try f.view("settings.capture.table-service", as: NSPopUpButton.self)
            service.selectItem(at: 1)
            try f.click("settings.capture.table-service")
            try await waitUntil { try f.shown("settings.capture.table-address") }
            try await waitUntil { try f.view("settings.capture.table-service", as: NSPopUpButton.self).indexOfSelectedItem == 1 }
        case "saved":
            try await f.saveKey("sk-live-00003f9a")
        case "testing":
            try await f.saveKey("sk-live-00003f9a")
            await f.transport.hold()
            try f.click("settings.capture.table-test")
            try await waitUntil { await f.transport.waiting }
        default:
            try await f.saveKey("sk-live-00003f9a")
            if let reply = reply871(testCase) { await f.transport.queue(reply) }
            try f.click("settings.capture.table-test")
            try await waitUntil {
                try !f.text("settings.capture.table-test-status").isEmpty
                    && f.view("settings.capture.table-test", as: NSButton.self).title == (locale == "en" ? "Test" : "测试")
            }
        }
        try expectFitsAndApart871(f, "\(locale) \(testCase)")
        if testCase == "testing" {
            try f.click("settings.capture.table-test")
            await f.transport.open()
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["address", "model"])
func issue871Fix1AddressAndModelFailuresOpenAdvanced(_ testCase: String) async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    #expect(try !f.shown("settings.capture.table-address"))
    await f.transport.queue(try #require(reply871(testCase)))
    try f.click("settings.capture.table-test")
    try await waitUntil { try !f.text("settings.capture.table-test-status").isEmpty }
    try await waitUntil { try f.view("settings.capture.table-test", as: NSButton.self).title == "测试" }
    // State 35 `case=address|model`: the rows the message points at are shown.
    #expect(try f.shown("settings.capture.table-address") && f.shown("settings.capture.table-model"))
    #expect(try f.view("settings.capture.table-advanced", as: NSButton.self).state == .on)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix1OtherFailuresLeaveAdvancedClosed() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    await f.transport.queue(try #require(reply871("key")))
    try f.click("settings.capture.table-test")
    try await waitUntil { try f.text("settings.capture.table-test-status") == "⚠ 密钥不被接受，请更换密钥。" }
    #expect(try !f.shown("settings.capture.table-address"))
}

private func sentModel871(_ request: URLRequest) -> String? {
    guard let body = request.httpBody,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return json["model"] as? String
}

/// Opens Advanced and types into a field without ending editing (no Return, Tab or focus change).
@MainActor private func typeWithoutCommitting871(_ f: Fixture871App, _ id: String, _ text: String) async throws {
    let advanced = try f.view("settings.capture.table-advanced", as: NSButton.self)
    advanced.state = .on
    try f.click("settings.capture.table-advanced")
    try f.view(id, as: NSTextField.self).stringValue = text
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix1TestSendsTheModelTheFieldShows() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    try await typeWithoutCommitting871(f, "settings.capture.table-model", "deepseek-vision")
    try f.click("settings.capture.table-test")
    try await waitUntil { try f.text("settings.capture.table-test-status") == "✓ 测试成功，可以识别示例表格。" }
    let requests = await f.transport.requests
    #expect(requests.count == 1)
    #expect(requests.first.flatMap(sentModel871) == "deepseek-vision")
    #expect(await f.table.stored.deepSeekModel == "deepseek-vision")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix1TestNeverSendsToTheOldAddressWhileANewOneIsTyped() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    try await typeWithoutCommitting871(f, "settings.capture.table-address", "https://gw.example.com/v1")
    try f.click("settings.capture.table-test")
    // The typed address is committed first; it has no key, so nothing is sent anywhere.
    try await waitUntil { try f.text("settings.capture.table-host") == "gw.example.com" }
    try await waitUntil { try f.view("settings.capture.table-test", as: NSButton.self).title == "测试" }
    #expect(await f.table.stored.deepSeekAddress == "https://gw.example.com/v1")
    #expect(await f.transport.requests.isEmpty)
    #expect(try f.shown("settings.capture.table-key"))
    #expect(try !f.view("settings.capture.table-test", as: NSButton.self).isEnabled)
    #expect(try f.text("settings.capture.table-test-status").isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix1ChangingTheAddressRemovesTheKeyAndSaysSo() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    let advanced = try f.view("settings.capture.table-advanced", as: NSButton.self)
    advanced.state = .on
    try f.click("settings.capture.table-advanced")
    #expect(try f.text("settings.capture.table-address-hint") == "换地址会移除已保存的密钥，需要重新保存并同意。")
    let address = try f.view("settings.capture.table-address", as: NSTextField.self)
    address.stringValue = "https://gw.example.com/v1"
    try f.click("settings.capture.table-address")
    try await waitUntil { try f.text("settings.capture.table-host") == "gw.example.com" }
    #expect(await f.secrets.items.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix1CustomSavesAKeyOnlyOnceAddressAndModelAreFilled() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    let service = try f.view("settings.capture.table-service", as: NSPopUpButton.self)
    service.selectItem(at: 1)
    try f.click("settings.capture.table-service")
    try await waitUntil { try f.text("settings.capture.table-host") == "（先填写地址）" }
    #expect(try !f.view("settings.capture.table-save", as: NSButton.self).isEnabled)
    let address = try f.view("settings.capture.table-address", as: NSTextField.self)
    address.stringValue = "https://gw.example.com/v1"
    try f.click("settings.capture.table-address")
    // An address but no model yet: the host row asks for the model, not the address.
    try await waitUntil { try f.text("settings.capture.table-host") == "（先填写模型）" }
    #expect(try !f.view("settings.capture.table-save", as: NSButton.self).isEnabled)
    let model = try f.view("settings.capture.table-model", as: NSTextField.self)
    model.stringValue = "vision-x"
    try f.click("settings.capture.table-model")
    try await waitUntil { try f.text("settings.capture.table-host") == "gw.example.com" }
    #expect(try f.view("settings.capture.table-save", as: NSButton.self).isEnabled)
    try await f.saveKey("sk-cu-00000002")
    #expect(await f.secrets.items.count == 1)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix1ClickingTheAdvancedTitleToggles() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await waitUntil { try f.text("settings.capture.table-host") == "api.deepseek.com" }
    let title = try f.view("settings.capture.table-advanced-title", as: NSTextField.self)
    let click = try #require(title.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
    let action = try #require(click.action)
    NSApp.sendAction(action, to: click.target, from: click)
    #expect(try f.shown("settings.capture.table-address"))
    #expect(try f.view("settings.capture.table-advanced", as: NSButton.self).state == .on)
    NSApp.sendAction(action, to: click.target, from: click)
    #expect(try !f.shown("settings.capture.table-address"))
}

// MARK: - Fix round 2: a failed keychain removal is shown, not swallowed (gpt F5 / opus N1); the Test commit is one
// change among the others (opus N2)

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue871Fix2AFailedKeyRemovalKeepsTheAddressAndSaysSo(_ locale: String) async throws {
    let f = try fixture871App(locale)
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    await f.secrets.failRemoval()
    let advanced = try f.view("settings.capture.table-advanced", as: NSButton.self)
    advanced.state = .on
    try f.click("settings.capture.table-advanced")
    let address = try f.view("settings.capture.table-address", as: NSTextField.self)
    address.stringValue = "https://gw.example.com/v1"
    try f.click("settings.capture.table-address")
    let line = locale == "en" ? "Could not remove the saved key. The address was not changed."
                              : "无法移除已保存的密钥，地址未更改。"
    try await waitUntil { try f.shown("settings.capture.table-key-message") && f.text("settings.capture.table-key-message") == line }
    // The field shows the old address again; the old configuration and its key stay on screen and removable.
    try await waitUntil { address.stringValue == TableRecognitionEndpoint.deepSeekBaseURL }
    #expect(try f.text("settings.capture.table-host") == "api.deepseek.com")
    #expect(try f.shown("settings.capture.table-saved-key") && f.shown("settings.capture.table-remove"))
    #expect(await f.table.stored.deepSeekAddress == TableRecognitionEndpoint.deepSeekBaseURL)
    #expect(await f.secrets.items.count == 1)
    #expect(await f.table.consents["api.deepseek.com"] == true)
    try expectFitsAndApart871(f, "\(locale) remove-failed")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix2TestWithATypedAddressSendsNothingWhenTheKeyCannotBeRemoved() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await f.saveKey("sk-live-00003f9a")
    await f.secrets.failRemoval()
    try await typeWithoutCommitting871(f, "settings.capture.table-address", "https://gw.example.com/v1")
    try f.click("settings.capture.table-test")
    try await waitUntil { try f.text("settings.capture.table-key-message") == "无法移除已保存的密钥，地址未更改。" }
    try await waitUntil { try f.view("settings.capture.table-test", as: NSButton.self).title == "测试" }
    // Neither the typed address nor the old one is tested: the user asked to test the typed one.
    #expect(await f.transport.requests.isEmpty)
    #expect(await f.table.stored.deepSeekAddress == TableRecognitionEndpoint.deepSeekBaseURL)
    #expect(try f.text("settings.capture.table-address") == TableRecognitionEndpoint.deepSeekBaseURL)
    #expect(try f.text("settings.capture.table-test-status").isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue871Fix2ServiceChangeDuringTheTestCommitIsNotMixedIn() async throws {
    let f = try fixture871App()
    defer { f.panel.window.close() }
    try await waitUntil { try f.text("settings.capture.table-host") == "api.deepseek.com" }
    try await typeWithoutCommitting871(f, "settings.capture.table-model", "deepseek-vision")
    // Test commits the typed model; its first read is held while the user picks Custom.
    await f.table.holdRead()
    try f.click("settings.capture.table-test")
    try await waitUntil { await f.table.readWaiting }
    let service = try f.view("settings.capture.table-service", as: NSPopUpButton.self)
    service.selectItem(at: 1)
    try f.click("settings.capture.table-service")
    await f.table.releaseRead()
    try await waitUntil { try f.view("settings.capture.table-test", as: NSButton.self).title == "测试" }
    try await waitUntil { await f.table.stored.deepSeekModel == "deepseek-vision" }
    // The DeepSeek field's model never lands in Custom's model.
    #expect(await f.table.stored.customModel == "")
}
