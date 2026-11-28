import Foundation
import MadoApplication
import MadoInfrastructure
import Network
import OSLog
import Security

/// The Cloud Recognition keys as generic passwords in the user's keychain (ADR-0019): readable after the first
/// unlock, never synchronised to iCloud. The App sandbox's own keychain access needs no entitlement change.
struct KeychainSecretStore: CloudSecretStorePort {
    static func itemQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    static func addAttributes(_ value: Data) -> [String: Any] {
        [kSecValueData as String: value, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
    }

    func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? {
        var query = Self.itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw .failed(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
        let query = Self.itemQuery(service: service, account: account)
        let attributes = Self.addAttributes(Data(value.utf8))
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .failed(status: status) }
    }

    func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) {
        let status = SecItemDelete(Self.itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .failed(status: status) }
    }
}

/// The latest network path. Until the monitor first reports, the Mac counts as online: a real offline then
/// surfaces as the transport's offline fallback, which the result labels.
actor NWPathReachability: NetworkReachabilityPort {
    private let monitor = NWPathMonitor()
    private var satisfied: Bool?

    init(startMonitoring: Bool = true) {
        guard startMonitoring else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { await self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.anzchy.mado.cloud-recognition.path"))
    }

    private func update(_ online: Bool) { satisfied = online }

    func isOnline() async -> Bool { satisfied ?? true }
}

/// Mado's one set of Cloud Recognition objects: Settings and Recognise Text share the switch, the consent
/// answer, the keychain keys and one Baidu provider (so its access token is cached once).
enum CloudRecognitionAppServices {
    static let keychainService = BaiduCloudCredentialStore.service
    static let preferences: any CloudRecognitionPreferencePort = UserDefaultsCloudRecognitionPreferences(defaults: .standard)
    static let keys = BaiduCloudCredentialStore(secrets: KeychainSecretStore(), service: keychainService)
    static let reachability = NWPathReachability()
    /// #689b dev1/dev2: one line per delivered explicit Recognise Text (engine, skip or fallback reason) and one per
    /// failed Baidu attempt (stage, HTTP status, error_code, a fixed reason id, or the transport error's code). The
    /// strings are built only from enums, numbers and local error type or domain names, never from server text, keys,
    /// the token or the image, so they are public; watch with `log stream --predicate 'subsystem ==
    /// "io.github.anzchy.mado" && category == "cloud-recognition"'`.
    static let logger = Logger(subsystem: "io.github.anzchy.mado", category: "cloud-recognition")
    static let cloud = BaiduTextRecognitionProvider(transport: URLSessionHTTPTransport(), onFailure: { detail in
        logger.notice("\(detail.logMessage, privacy: .public)")
    })

    static var settingsModel: CloudRecognitionSettingsModel {
        CloudRecognitionSettingsModel(preferences: preferences, keys: keys)
    }

    /// #871: Table Recognition shares the global switch (`preferences`) but keeps its own per-host consent, its own
    /// keychain service (one key per service configuration) and the real transport (#890). One model, so the last
    /// Test result survives closing and reopening Settings.
    static let tablePreferences: any TableRecognitionPreferencePort =
        UserDefaultsTableRecognitionPreferences(defaults: .standard)
    static let tableKeys = TableRecognitionKeyStore(secrets: KeychainSecretStore())
    /// #874: what View › 识别表格… reads before every request (the global switch, the endpoint, its host's consent)
    /// and the real transport it sends with (#890: only the consented host, no redirects).
    static var tableConfiguration: TableRecognitionConfiguration {
        TableRecognitionConfiguration(cloud: preferences, preferences: tablePreferences)
    }
    static let tableTransport: any HTTPTransport = URLSessionHTTPTransport()
    static let tableSettingsModel = TableRecognitionSettingsModel(cloud: preferences, preferences: tablePreferences,
                                                                  keys: tableKeys, transport: URLSessionHTTPTransport())

    /// The service Recognise Text uses (#687b wires it into the action).
    static func recognitionService(onDevice: any OnDeviceTextRecognitionProviding) -> TextRecognitionService {
        CloudRecognitionConfiguration.service(onDevice: onDevice, preferences: preferences, keys: keys,
                                              reachability: reachability, cloud: cloud, report: { outcome in
            logger.notice("recognise-text \(outcome.logMessage, privacy: .public)")
        })
    }
}
