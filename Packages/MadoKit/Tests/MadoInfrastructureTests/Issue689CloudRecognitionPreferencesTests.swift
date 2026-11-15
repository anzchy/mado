import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2)))
func issue689PreferencesPersistSwitchAndConsentInUserDefaults() async throws {
    let suite = "issue689-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsCloudRecognitionPreferences(defaults: defaults)
    #expect(await preferences.isEnabled() == false)
    #expect(await preferences.consentRecord() == nil)
    await preferences.setEnabled(true)
    let day = Date(timeIntervalSince1970: 1_763_000_000)
    await preferences.setConsentRecord(CloudRecognitionConsentRecord(granted: true, date: day))
    let reread = UserDefaultsCloudRecognitionPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(await reread.isEnabled())
    #expect(await reread.consentRecord() == CloudRecognitionConsentRecord(granted: true, date: day))
    await reread.setConsentRecord(CloudRecognitionConsentRecord(granted: false, date: day.addingTimeInterval(60)))
    #expect(await preferences.consentRecord() == CloudRecognitionConsentRecord(granted: false, date: day.addingTimeInterval(60)))
    await preferences.setEnabled(false)
    #expect(await reread.isEnabled() == false)
    // Exactly the switch and the consent answer; the keys live only in the keychain.
    let stored = defaults.persistentDomain(forName: suite) ?? [:]
    #expect(Set(stored.keys) == ["cloudRecognition.enabled.v1", "cloudRecognition.consentGranted.v1",
                                 "cloudRecognition.consentDate.v1"])
}

@Test(.timeLimit(.minutes(2)))
func issue689PreferencesIgnoreAHalfConsentRecord() async throws {
    let suite = "issue689-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "cloudRecognition.consentGranted.v1")
    #expect(await UserDefaultsCloudRecognitionPreferences(defaults: defaults).consentRecord() == nil)
}
