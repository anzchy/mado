import Foundation

/// Whether the Mac has a usable network path right now (the App implements it over NWPathMonitor).
public protocol NetworkReachabilityPort: Sendable {
    func isOnline() async -> Bool
}

/// Turns the Settings switch, the consent answer and the keychain keys into slice A's engine-choice inputs.
/// `TextRecognitionService` then picks Baidu only for an explicit Recognise Text with everything allowed, and
/// otherwise uses On-device Recognition with its label (ADR-0019, grilling 1.2–1.4).
public struct CloudRecognitionConfiguration: CloudRecognitionSettings {
    private let preferences: any CloudRecognitionPreferencePort
    private let reachability: any NetworkReachabilityPort

    public init(preferences: any CloudRecognitionPreferencePort, reachability: any NetworkReachabilityPort) {
        self.preferences = preferences
        self.reachability = reachability
    }

    public func options() async -> CloudRecognitionOptions {
        CloudRecognitionOptions(enabled: await preferences.isEnabled(),
                                consent: CloudRecognitionConsent(await preferences.consentRecord()),
                                online: await reachability.isOnline())
    }

    public static func service(onDevice: any OnDeviceTextRecognitionProviding,
                               preferences: any CloudRecognitionPreferencePort,
                               keys: BaiduCloudCredentialStore,
                               reachability: any NetworkReachabilityPort,
                               cloud: any CloudTextRecognitionProviding) -> TextRecognitionService {
        TextRecognitionService(onDevice: onDevice,
                               settings: CloudRecognitionConfiguration(preferences: preferences, reachability: reachability),
                               credentialStore: keys, cloud: cloud)
    }
}
