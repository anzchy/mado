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

    public func storedSettings() async -> TableRecognitionStoredSettings {
        let defaultsValue = TableRecognitionStoredSettings.defaults
        return TableRecognitionStoredSettings(
            preset: defaults.string(forKey: Self.presetKey).flatMap(TableRecognitionPreset.init(rawValue:)) ?? .deepSeek,
            deepSeekAddress: defaults.string(forKey: Self.deepSeekAddressKey) ?? defaultsValue.deepSeekAddress,
            deepSeekModel: defaults.string(forKey: Self.deepSeekModelKey) ?? defaultsValue.deepSeekModel,
            customAddress: defaults.string(forKey: Self.customAddressKey) ?? "",
            customModel: defaults.string(forKey: Self.customModelKey) ?? "")
    }

    public func setStoredSettings(_ settings: TableRecognitionStoredSettings) async {
        defaults.set(settings.preset.rawValue, forKey: Self.presetKey)
        defaults.set(settings.deepSeekAddress, forKey: Self.deepSeekAddressKey)
        defaults.set(settings.deepSeekModel, forKey: Self.deepSeekModelKey)
        defaults.set(settings.customAddress, forKey: Self.customAddressKey)
        defaults.set(settings.customModel, forKey: Self.customModelKey)
    }

    private var consents: [String: Bool] {
        (defaults.dictionary(forKey: Self.consentKey) ?? [:]).compactMapValues { $0 as? Bool }
    }

    public func consent(forHost host: String) async -> Bool? { consents[host] }

    public func setConsent(_ granted: Bool?, forHost host: String) async {
        var all = consents
        all[host] = granted
        defaults.set(all, forKey: Self.consentKey)
    }
}
