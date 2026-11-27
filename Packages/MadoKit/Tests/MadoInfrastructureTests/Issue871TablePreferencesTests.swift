import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #871 WI-4: the Table Recognition preset, addresses, models and per-host consent in Mado's own defaults; never a key.

@Test(.timeLimit(.minutes(2)))
func issue871WI4DefaultsAreDeepSeekWhenNothingIsStored() async throws {
    let suite = "issue871-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsTableRecognitionPreferences(defaults: defaults)
    #expect(await preferences.storedSettings() == .defaults)
    #expect(await preferences.storedSettings().endpoint == .deepSeek)
    #expect(await preferences.consent(forHost: "api.deepseek.com") == nil)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI4SettingsAndPerHostConsentRoundTrip() async throws {
    let suite = "issue871-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsTableRecognitionPreferences(defaults: defaults)
    let stored = TableRecognitionStoredSettings(preset: .custom, deepSeekAddress: "https://api.deepseek.com/beta",
                                                deepSeekModel: "deepseek-vision", customAddress: "https://gw.example.com/v1",
                                                customModel: "vision-x")
    await preferences.setStoredSettings(stored)
    await preferences.setConsent(true, forHost: "api.deepseek.com")
    await preferences.setConsent(false, forHost: "gw.example.com")
    let reread = UserDefaultsTableRecognitionPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(await reread.storedSettings() == stored)
    #expect(await reread.storedSettings().endpoint == .init(preset: .custom, baseURL: "https://gw.example.com/v1",
                                                             model: "vision-x"))
    #expect(await reread.consent(forHost: "api.deepseek.com") == true)
    #expect(await reread.consent(forHost: "gw.example.com") == false)
    #expect(await reread.consent(forHost: "other.example.com") == nil)
    await reread.setConsent(nil, forHost: "api.deepseek.com")
    #expect(await preferences.consent(forHost: "api.deepseek.com") == nil)
    #expect(await preferences.consent(forHost: "gw.example.com") == false)
    // Only these keys; the access key lives in the keychain.
    let keys = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)
    #expect(keys.isSubset(of: ["tableRecognition.preset.v1", "tableRecognition.deepSeek.address.v1",
                               "tableRecognition.deepSeek.model.v1", "tableRecognition.custom.address.v1",
                               "tableRecognition.custom.model.v1", "tableRecognition.consentByHost.v1"]))
    #expect(!keys.isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func issue871WI4AnUnknownStoredPresetReadsAsDeepSeek() async throws {
    let suite = "issue871-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("openAI", forKey: "tableRecognition.preset.v1")
    let preferences = UserDefaultsTableRecognitionPreferences(defaults: defaults)
    #expect(await preferences.storedSettings().preset == .deepSeek)
}
