import Foundation
import Testing
@testable import MadoApplication

actor MemoryCloudRecognitionPreferences: CloudRecognitionPreferencePort {
    private(set) var enabled = false
    private(set) var record: CloudRecognitionConsentRecord?
    func isEnabled() async -> Bool { enabled }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func consentRecord() async -> CloudRecognitionConsentRecord? { record }
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async { self.record = record }
}

private let consentDay = Date(timeIntervalSince1970: 1_763_000_000)

private func settingsModel() -> (CloudRecognitionSettingsModel, MemoryCloudRecognitionPreferences, FakeSecretStore) {
    let preferences = MemoryCloudRecognitionPreferences()
    let secrets = FakeSecretStore()
    let model = CloudRecognitionSettingsModel(preferences: preferences, keys: BaiduCloudCredentialStore(secrets: secrets),
                                              now: { consentDay })
    return (model, preferences, secrets)
}

@Test(.timeLimit(.minutes(2)))
func issue689SwitchTurnsOnOnlyAfterKeysAndConsent() async throws {
    let (model, preferences, _) = settingsModel()
    #expect(await model.state() == CloudRecognitionSettingsState(isOn: false, hasKeys: false, consent: .notAsked, maskedAPIKey: nil))
    // No keys: the switch cannot turn on, and nobody is asked for consent yet.
    #expect(await model.requestEnable() == .needsKeys)
    #expect(await preferences.enabled == false)
    #expect(await preferences.record == nil)
    try await model.saveKeys(apiKey: "AK1234567890", secretKey: "SK-secret")
    #expect(await model.state() == CloudRecognitionSettingsState(isOn: false, hasKeys: true, consent: .notAsked, maskedAPIKey: "••••••••7890"))
    // Keys but no consent: ask first; the switch stays off.
    #expect(await model.requestEnable() == .needsConsent)
    #expect(await preferences.enabled == false)
    #expect(await model.answerConsent(granted: true) == .enabled)
    #expect(await preferences.record == CloudRecognitionConsentRecord(granted: true, date: consentDay))
    #expect(await preferences.enabled)
    #expect(await model.state() == CloudRecognitionSettingsState(isOn: true, hasKeys: true, consent: .granted, maskedAPIKey: "••••••••7890"))
    // Consent is remembered: off and on again does not ask.
    await model.disable()
    #expect(await model.state().isOn == false)
    #expect(await model.requestEnable() == .enabled)
    #expect(await model.state().isOn)
}

@Test(.timeLimit(.minutes(2)))
func issue689ConsentCancelLeavesSwitchOffAndAsksAgain() async throws {
    let (model, preferences, _) = settingsModel()
    try await model.saveKeys(apiKey: "AK", secretKey: "SK")
    #expect(await model.requestEnable() == .needsConsent)
    #expect(await model.answerConsent(granted: false) == .needsConsent)
    #expect(await preferences.record == CloudRecognitionConsentRecord(granted: false, date: consentDay))
    #expect(await preferences.enabled == false)
    #expect(await model.state() == CloudRecognitionSettingsState(isOn: false, hasKeys: true, consent: .declined, maskedAPIKey: "••••••••"))
    #expect(await model.requestEnable() == .needsConsent)
    #expect(await model.answerConsent(granted: true) == .enabled)
}

@Test(.timeLimit(.minutes(2)))
func issue689ConsentWithoutKeysDoesNotTurnOn() async throws {
    let (model, preferences, _) = settingsModel()
    #expect(await model.answerConsent(granted: true) == .needsKeys)
    #expect(await preferences.record == CloudRecognitionConsentRecord(granted: true, date: consentDay))
    #expect(await preferences.enabled == false)
    #expect(await model.state() == CloudRecognitionSettingsState(isOn: false, hasKeys: false, consent: .granted, maskedAPIKey: nil))
}

@Test(.timeLimit(.minutes(2)))
func issue689RemovingKeysTurnsSwitchOff() async throws {
    let (model, preferences, secrets) = settingsModel()
    try await model.saveKeys(apiKey: "AK", secretKey: "SK")
    _ = await model.answerConsent(granted: true)
    #expect(await model.state().isOn)
    try await model.removeKeys()
    #expect(await secrets.items.isEmpty)
    #expect(await preferences.enabled == false)
    #expect(await model.state() == CloudRecognitionSettingsState(isOn: false, hasKeys: false, consent: .granted, maskedAPIKey: nil))
    // A stored "on" with the keys gone elsewhere reads as off.
    await preferences.setEnabled(true)
    #expect(await model.state().isOn == false)
    // A failed removal still turns the switch off and reports the failure.
    try await model.saveKeys(apiKey: "AK", secretKey: "SK")
    #expect(await model.requestEnable() == .enabled)
    await secrets.failRemove(on: "secret-key")
    await #expect(throws: CloudKeyError.storeFailed) { try await model.removeKeys() }
    #expect(await preferences.enabled == false)
}

@Test(.timeLimit(.minutes(2)))
func issue689SaveKeysReportsEmptyAndStoreFailures() async throws {
    let (model, _, secrets) = settingsModel()
    await #expect(throws: CloudKeyError.emptyKey) { try await model.saveKeys(apiKey: " ", secretKey: "SK") }
    await secrets.failSet(on: "api-key")
    await #expect(throws: CloudKeyError.storeFailed) { try await model.saveKeys(apiKey: "AK", secretKey: "SK") }
    #expect(await model.state().hasKeys == false)
}
