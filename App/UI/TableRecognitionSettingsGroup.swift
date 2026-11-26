import AppKit
import MadoApplication
import MadoMacUI

/// What the 表格识别 group needs: the settings model, how to show the consent dialog, and the help pages.
struct TableRecognitionSettingsEnvironment {
    typealias ConsentPresenter = CloudRecognitionSettingsEnvironment.ConsentPresenter
    let model: TableRecognitionSettingsModel
    let presentConsent: ConsentPresenter

    /// The App's keychain, defaults and real transport, and a sheet on the Settings window.
    @MainActor static var live: TableRecognitionSettingsEnvironment {
        TableRecognitionSettingsEnvironment(model: CloudRecognitionAppServices.tableSettingsModel) { window, alert, answer in
            if let window {
                alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
            } else {
                answer(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    /// For a Settings window built without the App's services (tests, fixtures): nothing is read from the keychain
    /// or the network, every request is refused, and the consent dialog is answered 取消.
    static func inMemory() -> TableRecognitionSettingsEnvironment {
        TableRecognitionSettingsEnvironment(
            model: TableRecognitionSettingsModel(cloud: MemoryCloud(), preferences: MemoryPreferences(),
                                                 keys: TableRecognitionKeyStore(secrets: MemorySecrets()),
                                                 transport: RefusingTransport()),
            presentConsent: { _, _, answer in answer(false) })
    }

    private actor MemorySecrets: CloudSecretStorePort {
        var items: [String: String] = [:]
        func secret(service: String, account: String) async throws(CloudSecretStoreError) -> String? { items[account] }
        func setSecret(_ value: String, service: String, account: String) async throws(CloudSecretStoreError) {
            items[account] = value
        }
        func removeSecret(service: String, account: String) async throws(CloudSecretStoreError) { items[account] = nil }
    }

    private actor MemoryCloud: CloudRecognitionPreferencePort {
        func isEnabled() async -> Bool { false }
        func setEnabled(_ enabled: Bool) async {}
        func consentRecord() async -> CloudRecognitionConsentRecord? { nil }
        func setConsentRecord(_ record: CloudRecognitionConsentRecord) async {}
    }

    private actor MemoryPreferences: TableRecognitionPreferencePort {
        var stored = TableRecognitionStoredSettings.defaults
        var consents: [String: Bool] = [:]
        func storedSettings() async -> TableRecognitionStoredSettings { stored }
        func setStoredSettings(_ settings: TableRecognitionStoredSettings) async { stored = settings }
        func consent(forHost host: String) async -> Bool? { consents[host] }
        func setConsent(_ granted: Bool?, forHost host: String) async { consents[host] = granted }
    }

    private struct RefusingTransport: HTTPTransport {
        func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// Settings › 截图 › 表格识别 (#871, state 35). Stub: rows land with WI-5.
@MainActor final class TableRecognitionSettingsGroup: NSView {
    init(width: CGFloat, labelWidth: CGFloat, valueX: CGFloat, environment: TableRecognitionSettingsEnvironment,
         localize: @escaping (String) -> String, openURL: @escaping (URL) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refresh() {}
}
