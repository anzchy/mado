import Foundation
import MadoApplication

/// The Cloud Recognition switch and consent answer in Mado's own defaults. The keys are never stored here.
public final class UserDefaultsCloudRecognitionPreferences: CloudRecognitionPreferencePort, @unchecked Sendable {
    static let enabledKey = "cloudRecognition.enabled.v1"
    static let consentGrantedKey = "cloudRecognition.consentGranted.v1"
    static let consentDateKey = "cloudRecognition.consentDate.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isEnabled() async -> Bool { defaults.bool(forKey: Self.enabledKey) }

    public func setEnabled(_ enabled: Bool) async { defaults.set(enabled, forKey: Self.enabledKey) }

    /// Both halves or nothing: a stray answer without its date reads as not asked.
    public func consentRecord() async -> CloudRecognitionConsentRecord? {
        guard let granted = defaults.object(forKey: Self.consentGrantedKey) as? Bool,
              let date = defaults.object(forKey: Self.consentDateKey) as? Date else { return nil }
        return CloudRecognitionConsentRecord(granted: granted, date: date)
    }

    public func setConsentRecord(_ record: CloudRecognitionConsentRecord) async {
        defaults.set(record.granted, forKey: Self.consentGrantedKey)
        defaults.set(record.date, forKey: Self.consentDateKey)
    }
}
