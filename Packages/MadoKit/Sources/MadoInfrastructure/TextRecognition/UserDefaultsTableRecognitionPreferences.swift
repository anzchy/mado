import Foundation
import MadoApplication

/// The Table Recognition preset, addresses, models and per-host consent answers in Mado's own defaults. The access
/// key is never stored here (it is in the keychain).
public final class UserDefaultsTableRecognitionPreferences: TableRecognitionPreferencePort, @unchecked Sendable {
    static let presetKey = "tableRecognition.preset.v1"
    static let deepSeekAddressKey = "tableRecognition.deepSeek.address.v1"
    static let deepSeekModelKey = "tableRecognition.deepSeek.model.v1"
    static let customAddressKey = "tableRecognition.custom.address.v1"
    static let customModelKey = "tableRecognition.custom.model.v1"
    static let consentKey = "tableRecognition.consentByHost.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func storedSettings() async -> TableRecognitionStoredSettings { .defaults }

    public func setStoredSettings(_ settings: TableRecognitionStoredSettings) async {}

    public func consent(forHost host: String) async -> Bool? { nil }

    public func setConsent(_ granted: Bool?, forHost host: String) async {}
}
