import Foundation

/// The non-secret Table Recognition settings: which preset is chosen and the address and model kept for each
/// (spec #866 decision 5). DeepSeek starts prefilled; Custom starts empty and needs both.
public struct TableRecognitionStoredSettings: Sendable, Equatable {
    public var preset: TableRecognitionPreset
    public var deepSeekAddress: String
    public var deepSeekModel: String
    public var customAddress: String
    public var customModel: String

    public init(preset: TableRecognitionPreset = .deepSeek,
                deepSeekAddress: String = TableRecognitionEndpoint.deepSeekBaseURL,
                deepSeekModel: String = TableRecognitionEndpoint.deepSeekModel,
                customAddress: String = "", customModel: String = "") {
        self.preset = preset
        self.deepSeekAddress = deepSeekAddress
        self.deepSeekModel = deepSeekModel
        self.customAddress = customAddress
        self.customModel = customModel
    }

    public static let defaults = TableRecognitionStoredSettings()

    /// The endpoint of the chosen preset.
    public var endpoint: TableRecognitionEndpoint {
        switch preset {
        case .deepSeek: TableRecognitionEndpoint(preset: .deepSeek, baseURL: deepSeekAddress, model: deepSeekModel)
        case .custom: TableRecognitionEndpoint(preset: .custom, baseURL: customAddress, model: customModel)
        }
    }
}

/// Where the table settings and the per-host consent answers are kept (UserDefaults in the App). Never the key.
public protocol TableRecognitionPreferencePort: Sendable {
    func storedSettings() async -> TableRecognitionStoredSettings
    func setStoredSettings(_ settings: TableRecognitionStoredSettings) async
    /// The consent answer for one host (already normalised by the caller), nil when never asked.
    func consent(forHost host: String) async -> Bool?
    /// Records an answer for one host; nil removes it.
    func setConsent(_ granted: Bool?, forHost host: String) async
}

/// The table service's access key in the keychain, one per service configuration (preset and address): a new
/// address never inherits the key saved for another (spec #866 decision 13).
public struct TableRecognitionKeyStore: TableRecognitionCredentialStore {
    public static let service = "io.github.anzchy.mado.table-recognition"

    private let secrets: any CloudSecretStorePort
    private let service: String

    public init(secrets: any CloudSecretStorePort, service: String = Self.service) {
        self.secrets = secrets
        self.service = service
    }

    /// The keychain account for one configuration: the preset and the address, compared the way a user means it
    /// (surrounding spaces, the case of the scheme and host, one trailing host dot and trailing slashes do not count).
    public static func account(for endpoint: TableRecognitionEndpoint) -> String {
        "\(endpoint.preset.rawValue)|\(canonicalAddress(endpoint.baseURL))"
    }

    static func canonicalAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let host = parts.host, !host.isEmpty else { return trimmed }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = TableRecognitionGuards.normalisedHost(host)
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path
        // Parsed with a host, so the path is empty or starts with "/": the parts always serialise again.
        return parts.string!
    }

    public func accessKey(for endpoint: TableRecognitionEndpoint) async -> String? {
        guard let key = try? await secrets.secret(service: service, account: Self.account(for: endpoint)),
              !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key trimmed, for this configuration only.
    public func save(_ key: String, for endpoint: TableRecognitionEndpoint) async throws(CloudKeyError) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw .emptyKey }
        do { try await secrets.setSecret(key, service: service, account: Self.account(for: endpoint)) }
        catch { throw .storeFailed }
    }

    public func remove(for endpoint: TableRecognitionEndpoint) async throws(CloudKeyError) {
        do { try await secrets.removeSecret(service: service, account: Self.account(for: endpoint)) }
        catch { throw .storeFailed }
    }
}

/// What the table service reads before every request: the global Allow Cloud Recognition switch (shared with text),
/// the chosen endpoint and the consent answer for that endpoint's host only. The Baidu consent is never read.
public struct TableRecognitionConfiguration: TableRecognitionSettings {
    private let cloud: any CloudRecognitionPreferencePort
    private let preferences: any TableRecognitionPreferencePort

    public init(cloud: any CloudRecognitionPreferencePort, preferences: any TableRecognitionPreferencePort) {
        self.cloud = cloud
        self.preferences = preferences
    }

    public func options() async -> TableRecognitionOptions {
        let enabled = await cloud.isEnabled()
        let endpoint = await preferences.storedSettings().endpoint
        var consent: TableRecognitionConsentRecord?
        if let host = TableRecognitionGuards.validURL(for: endpoint)?.host {
            let normalised = TableRecognitionGuards.normalisedHost(host)
            consent = await preferences.consent(forHost: normalised).map {
                TableRecognitionConsentRecord(host: normalised, granted: $0)
            }
        }
        return TableRecognitionOptions(cloudEnabled: enabled, endpoint: endpoint, consent: consent)
    }
}

/// What the Test row shows (state 35 cases testing, ok, key, address, model, offline, quota, unknown).
public enum TableRecognitionTestStatus: Sendable, Equatable {
    case testing
    case passed
    case keyRejected
    case addressUnreachable
    case modelCannotReadImages
    case offline
    case quotaOrBalance
    /// 「测试未通过」: no guess at the cause.
    case undetermined
    /// The global switch is off; nothing was sent.
    case cloudOff
}

/// How a Test click ended: a status for the row (nil when cancelled or superseded), or the host whose consent is
/// needed before anything is sent.
public enum TableRecognitionTestOutcome: Sendable, Equatable {
    case finished(TableRecognitionTestStatus?)
    case needsConsent(host: String)
}

/// What the user has to fill in before the address is usable (「（先填写地址）」 or 「（先填写模型）」).
public enum TableRecognitionMissing: Sendable, Equatable {
    case address
    case model
}

public struct TableRecognitionSettingsState: Sendable, Equatable {
    public let preset: TableRecognitionPreset
    public let address: String
    public let model: String
    /// The host 「图片发送到」 names; nil when the address is not usable yet (「（先填写地址）」).
    public let host: String?
    public let hasKey: Bool
    public let maskedKey: String?
    /// Custom: Advanced opens by itself and address and model are required.
    public let advancedRequired: Bool
    /// A key is saved and the address is usable.
    public let canTest: Bool
    public let test: TableRecognitionTestStatus?
    /// nil when the address is usable (`host` is set).
    public let missing: TableRecognitionMissing?
    /// The last address change was refused because the old configuration's key could not be removed from the
    /// keychain: the address, its key and its consent are as they were.
    public let addressChangeFailed: Bool

    public init(preset: TableRecognitionPreset, address: String, model: String, host: String?, hasKey: Bool,
                maskedKey: String?, advancedRequired: Bool, canTest: Bool, test: TableRecognitionTestStatus?,
                missing: TableRecognitionMissing? = nil, addressChangeFailed: Bool = false) {
        self.preset = preset; self.address = address; self.model = model; self.host = host; self.hasKey = hasKey
        self.maskedKey = maskedKey; self.advancedRequired = advancedRequired; self.canTest = canTest; self.test = test
        self.missing = missing; self.addressChangeFailed = addressChangeFailed
    }

    /// State 35 draws twelve dots and the key's last four characters.
    public static func masked(_ key: String) -> String {
        let dots = String(repeating: "•", count: 12)
        return key.count >= 8 ? dots + String(key.suffix(4)) : dots
    }
}

/// The rules behind Settings › 截图 › 表格识别 (#871, state 35): preset, key per configuration, the real host, the
/// Test of the built-in sample under the switch and per-host consent, and what a changed address or model clears.
public actor TableRecognitionSettingsModel {
    private let cloud: any CloudRecognitionPreferencePort
    private let preferences: any TableRecognitionPreferencePort
    private let keys: TableRecognitionKeyStore
    private let transport: any HTTPTransport

    public init(cloud: any CloudRecognitionPreferencePort, preferences: any TableRecognitionPreferencePort,
                keys: TableRecognitionKeyStore, transport: any HTTPTransport) {
        self.cloud = cloud
        self.preferences = preferences
        self.keys = keys
        self.transport = transport
    }

    /// The last Test's status, and a counter that every change of preset, address, model or key moves on, so a
    /// Test still in flight cannot report on settings that are no longer there.
    private var testStatus: TableRecognitionTestStatus?
    private var generation = 0
    /// The last address change was refused (its old key could not be removed); any later change clears it.
    private var addressChangeFailed = false

    private func invalidateTest() {
        generation += 1
        testStatus = nil
        addressChangeFailed = false
    }

    public func state() async -> TableRecognitionSettingsState {
        let stored = await preferences.storedSettings()
        let endpoint = stored.endpoint
        let key = await keys.accessKey(for: endpoint)
        let host = TableRecognitionGuards.validURL(for: endpoint).map { TableRecognitionGuards.normalisedHost($0.host) }
        // Unusable: the address itself, or (Custom) only the model is missing.
        let withModel = TableRecognitionEndpoint(preset: endpoint.preset, baseURL: endpoint.baseURL, model: "model")
        let missing: TableRecognitionMissing? = host != nil ? nil
            : TableRecognitionGuards.validURL(for: withModel) == nil ? .address : .model
        return TableRecognitionSettingsState(preset: stored.preset, address: endpoint.baseURL, model: endpoint.model,
                                             host: host, hasKey: key != nil,
                                             maskedKey: key.map(TableRecognitionSettingsState.masked),
                                             advancedRequired: stored.preset == .custom,
                                             canTest: key != nil && host != nil, test: testStatus, missing: missing,
                                             addressChangeFailed: addressChangeFailed)
    }

    public func selectPreset(_ preset: TableRecognitionPreset) async {
        var stored = await preferences.storedSettings()
        guard stored.preset != preset else { return }
        stored.preset = preset
        await preferences.setStoredSettings(stored)
        invalidateTest()
    }

    /// A different address (not just other spacing, case or a trailing slash) drops the old host's consent and the
    /// Test result, and removes the key saved for the old address, so no key is left that the group can no longer
    /// show or remove (the hint says so). The other preset's key stays. When the keychain refuses that removal
    /// (nothing saved is not a refusal), nothing changes: the old address, its key and its consent stay, and the state
    /// says the address was not changed.
    public func setAddress(_ address: String) async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored = await preferences.storedSettings()
        let old = stored.endpoint
        guard TableRecognitionKeyStore.canonicalAddress(old.baseURL) != TableRecognitionKeyStore.canonicalAddress(address)
        else { return }
        do throws(CloudKeyError) { try await keys.remove(for: old) } catch {
            addressChangeFailed = true
            return
        }
        let oldAddress = old.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URLComponents(string: oldAddress)?.host, !host.isEmpty {
            await preferences.setConsent(nil, forHost: TableRecognitionGuards.normalisedHost(host))
        }
        switch stored.preset {
        case .deepSeek: stored.deepSeekAddress = address
        case .custom: stored.customAddress = address
        }
        await preferences.setStoredSettings(stored)
        invalidateTest()
    }

    /// A different model clears the Test result (spec #866 story 12); the key and the consent stay.
    public func setModel(_ model: String) async {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored = await preferences.storedSettings()
        guard stored.endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines) != model else { return }
        switch stored.preset {
        case .deepSeek: stored.deepSeekModel = model
        case .custom: stored.customModel = model
        }
        await preferences.setStoredSettings(stored)
        invalidateTest()
    }

    /// Saves the key for the configuration shown. Until the address is usable there is no configuration to save it
    /// for (Custom filled top to bottom), so it is refused rather than kept under an address that is about to change.
    public func saveKey(_ key: String) async throws(CloudKeyError) {
        let endpoint = await preferences.storedSettings().endpoint
        guard TableRecognitionGuards.validURL(for: endpoint) != nil else { throw .addressNeeded }
        try await keys.save(key, for: endpoint)
        invalidateTest()
    }

    public func removeKey() async throws(CloudKeyError) {
        let endpoint = await preferences.storedSettings().endpoint
        invalidateTest()
        try await keys.remove(for: endpoint)
    }

    /// Runs the real service's Test (switch, consent, key, the built-in sample). A missing consent returns the
    /// host to ask about and sends nothing; a cancelled or superseded run shows nothing.
    public func test() async -> TableRecognitionTestOutcome {
        let started = generation
        testStatus = .testing
        let service = TableRecognitionService(settings: TableRecognitionConfiguration(cloud: cloud, preferences: preferences),
                                              credentials: keys, transport: transport)
        let result = await service.testService()
        guard started == generation else { return .finished(nil) }
        switch result {
        case .notSent(.consentNotAsked), .notSent(.consentHostChanged), .notSent(.consentDeclined):
            let endpoint = await preferences.storedSettings().endpoint
            if let host = TableRecognitionGuards.validURL(for: endpoint)?.host {
                testStatus = nil
                return .needsConsent(host: TableRecognitionGuards.normalisedHost(host))
            }
            testStatus = .undetermined
        case .cancelled:
            testStatus = nil
        default:
            testStatus = Self.status(result)
        }
        return .finished(testStatus)
    }

    static func status(_ result: TableRecognitionTestResult) -> TableRecognitionTestStatus? {
        switch result {
        case .passed: .passed
        case .cancelled: nil
        case .notSent(.cloudOff): .cloudOff
        case .notSent: .undetermined
        case .failed(.keyRejected): .keyRejected
        case .failed(.addressUnreachable): .addressUnreachable
        case .failed(.modelCannotReadImages): .modelCannotReadImages
        case .failed(.offline): .offline
        case .failed(.quotaOrBalance): .quotaOrBalance
        case .failed(.tooLarge), .failed(.noTable), .failed(.incomplete), .failed(.other): .undetermined
        }
    }

    /// The consent dialog's answer for `host`. Agreeing stores it for that host; declining changes nothing.
    public func answerConsent(granted: Bool, host: String) async {
        guard granted else { return }
        await preferences.setConsent(true, forHost: TableRecognitionGuards.normalisedHost(host))
    }
}
