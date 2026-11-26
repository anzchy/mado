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
        TableRecognitionEndpoint(preset: preset, baseURL: "", model: "")
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

    /// The keychain account for one configuration.
    public static func account(for endpoint: TableRecognitionEndpoint) -> String { "" }

    public func accessKey(for endpoint: TableRecognitionEndpoint) async -> String? { nil }

    public func save(_ key: String, for endpoint: TableRecognitionEndpoint) async throws(CloudKeyError) {}

    public func remove(for endpoint: TableRecognitionEndpoint) async throws(CloudKeyError) {}
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
        TableRecognitionOptions(cloudEnabled: false, endpoint: nil, consent: nil)
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

    public init(preset: TableRecognitionPreset, address: String, model: String, host: String?, hasKey: Bool,
                maskedKey: String?, advancedRequired: Bool, canTest: Bool, test: TableRecognitionTestStatus?) {
        self.preset = preset; self.address = address; self.model = model; self.host = host; self.hasKey = hasKey
        self.maskedKey = maskedKey; self.advancedRequired = advancedRequired; self.canTest = canTest; self.test = test
    }

    /// State 35 draws twelve dots and the key's last four characters.
    public static func masked(_ key: String) -> String { "" }
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

    public func state() async -> TableRecognitionSettingsState {
        TableRecognitionSettingsState(preset: .deepSeek, address: "", model: "", host: nil, hasKey: false,
                                      maskedKey: nil, advancedRequired: false, canTest: false, test: nil)
    }

    public func selectPreset(_ preset: TableRecognitionPreset) async {}

    public func setAddress(_ address: String) async {}

    public func setModel(_ model: String) async {}

    public func saveKey(_ key: String) async throws(CloudKeyError) {}

    public func removeKey() async throws(CloudKeyError) {}

    public func test() async -> TableRecognitionTestOutcome { .finished(nil) }

    /// The consent dialog's answer for `host`. Agreeing stores it for that host; declining changes nothing.
    public func answerConsent(granted: Bool, host: String) async {}
}
