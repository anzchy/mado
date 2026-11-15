import Foundation

/// The user's answer to the Cloud Recognition consent dialog, and when they gave it (ADR-0019, grilling 1.2).
public struct CloudRecognitionConsentRecord: Equatable, Sendable {
    public let granted: Bool
    public let date: Date
    public init(granted: Bool, date: Date) { self.granted = granted; self.date = date }
}

/// The global switch and the consent answer. Never the keys: those are in the keychain only.
public protocol CloudRecognitionPreferencePort: Sendable {
    func isEnabled() async -> Bool
    func setEnabled(_ enabled: Bool) async
    func consentRecord() async -> CloudRecognitionConsentRecord?
    func setConsentRecord(_ record: CloudRecognitionConsentRecord) async
}

extension CloudRecognitionConsent: Equatable {
    init(_ record: CloudRecognitionConsentRecord?) {
        switch record?.granted {
        case nil: self = .notAsked
        case false?: self = .declined
        case true?: self = .granted
        }
    }
}

/// What turning the switch on did: refused for want of keys, waits for consent, or turned it on.
public enum CloudRecognitionEnableResult: Equatable, Sendable { case needsKeys, needsConsent, enabled }

public struct CloudRecognitionSettingsState: Equatable, Sendable {
    /// On only when the switch is on, both keys are saved and consent was given (settings.html line 23).
    public let isOn: Bool
    public let hasKeys: Bool
    public let consent: CloudRecognitionConsent
    public let maskedAPIKey: String?
    public init(isOn: Bool, hasKeys: Bool, consent: CloudRecognitionConsent, maskedAPIKey: String?) {
        self.isOn = isOn; self.hasKeys = hasKeys; self.consent = consent; self.maskedAPIKey = maskedAPIKey
    }
}

/// The rules behind Settings › Screenshots › 文字识别: the switch turns on only after both keys are saved and the
/// user agreed once; cancelling the dialog leaves it off and asks again next time; removing the keys turns it off.
public struct CloudRecognitionSettingsModel: Sendable {
    private let preferences: any CloudRecognitionPreferencePort
    private let keys: BaiduCloudCredentialStore
    private let now: @Sendable () -> Date

    public init(preferences: any CloudRecognitionPreferencePort, keys: BaiduCloudCredentialStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.preferences = preferences
        self.keys = keys
        self.now = now
    }

    public func state() async -> CloudRecognitionSettingsState {
        let credentials = await keys.credentials()
        let consent = CloudRecognitionConsent(await preferences.consentRecord())
        let enabled = await preferences.isEnabled()
        return CloudRecognitionSettingsState(isOn: enabled && credentials != nil && consent == .granted,
                                             hasKeys: credentials != nil, consent: consent,
                                             maskedAPIKey: credentials.map { CloudKeyMask.masked($0.apiKey) })
    }

    public func requestEnable() async -> CloudRecognitionEnableResult {
        guard await keys.hasKeys() else {
            await preferences.setEnabled(false)
            return .needsKeys
        }
        guard CloudRecognitionConsent(await preferences.consentRecord()) == .granted else { return .needsConsent }
        await preferences.setEnabled(true)
        return .enabled
    }

    /// Records the dialog's answer with today's date; agreeing turns the switch on when the keys are there.
    public func answerConsent(granted: Bool) async -> CloudRecognitionEnableResult {
        await preferences.setConsentRecord(CloudRecognitionConsentRecord(granted: granted, date: now()))
        return granted ? await requestEnable() : .needsConsent
    }

    public func disable() async { await preferences.setEnabled(false) }

    public func saveKeys(apiKey: String, secretKey: String) async throws(CloudKeyError) {
        try await keys.save(CloudCredentials(apiKey: apiKey, secretKey: secretKey))
    }

    /// Turns the switch off first, so a failed keychain removal still stops cloud use.
    public func removeKeys() async throws(CloudKeyError) {
        await preferences.setEnabled(false)
        try await keys.remove()
    }
}
