import Foundation

public enum TextRecognitionIntent: Sendable {
    case selection
    case explicit
}

public enum TextRecognitionEngine: Sendable {
    case onDevice
    case cloud
}

public enum TextRecognitionError: Error, Equatable, Sendable {
    case invalidImage
    case cancelled
    case recognitionFailed(domain: String, code: Int)
    case cloudAuth
    case cloudQuota
    case cloudOffline
    case cloudFailure
    case cloudImageTooLarge
}

public enum CloudRecognitionConsent: Sendable { case notAsked, declined, granted }
public struct CloudRecognitionOptions: Sendable {
    public let enabled: Bool
    public let consent: CloudRecognitionConsent
    public let online: Bool
    public init(enabled: Bool, consent: CloudRecognitionConsent, online: Bool) {
        self.enabled = enabled; self.consent = consent; self.online = online
    }
}
public protocol CloudRecognitionSettings: Sendable {
    func options() async -> CloudRecognitionOptions
}
public struct CloudCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let apiKey: String
    public let secretKey: String
    public init(apiKey: String, secretKey: String) { self.apiKey = apiKey; self.secretKey = secretKey }
    public var description: String { "CloudCredentials(apiKey: <redacted>, secretKey: <redacted>)" }
    public var debugDescription: String { description }
}
public protocol CloudCredentialStore: Sendable {
    func credentials() async -> CloudCredentials?
}
public enum CloudFallbackReason: Sendable, Equatable { case auth, quota, offline, failure }

public struct TextRecognitionResult: Sendable {
    public let text: String
    public let characterCount: Int
    public let engine: TextRecognitionEngine
    public let isEmpty: Bool
    public let fallbackReason: CloudFallbackReason?

    public init(text: String, characterCount: Int, engine: TextRecognitionEngine, isEmpty: Bool, fallbackReason: CloudFallbackReason? = nil) {
        self.text = text
        self.characterCount = characterCount
        self.engine = engine
        self.isEmpty = isEmpty
        self.fallbackReason = fallbackReason
    }
}

public protocol OnDeviceTextRecognitionProviding: Sendable {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String
}

public protocol CloudTextRecognitionProviding: Sendable {
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String
}

public struct TextRecognitionService: Sendable {
    private let onDevice: any OnDeviceTextRecognitionProviding
    private let settings: (any CloudRecognitionSettings)?
    private let credentialStore: (any CloudCredentialStore)?
    private let cloud: (any CloudTextRecognitionProviding)?

    public init(onDevice: any OnDeviceTextRecognitionProviding, settings: (any CloudRecognitionSettings)? = nil, credentialStore: (any CloudCredentialStore)? = nil, cloud: (any CloudTextRecognitionProviding)? = nil) {
        self.onDevice = onDevice
        self.settings = settings; self.credentialStore = credentialStore; self.cloud = cloud
    }

    public func recognise(_ image: Data, intent: TextRecognitionIntent) async throws(TextRecognitionError) -> TextRecognitionResult {
        if Task.isCancelled { throw TextRecognitionError.cancelled }
        if case .explicit = intent, let settings, let credentialStore, let cloud {
            let options = await settings.options()
            if options.enabled, case .granted = options.consent, options.online,
               let credentials = await credentialStore.credentials(),
               !credentials.apiKey.isEmpty, !credentials.secretKey.isEmpty {
                do {
                    let text = try await cloud.recognise(image, credentials: credentials)
                    if Task.isCancelled { throw TextRecognitionError.cancelled }
                    return TextRecognitionResult(text: text, characterCount: text.count, engine: .cloud, isEmpty: text.isEmpty)
                } catch {
                    let cloudError = error as? TextRecognitionError
                    if Task.isCancelled || cloudError == .cancelled { throw TextRecognitionError.cancelled }
                    let reason: CloudFallbackReason = switch cloudError {
                    case .cloudAuth?: .auth
                    case .cloudQuota?: .quota
                    case .cloudOffline?: .offline
                    default: .failure
                    }
                    let text = try await onDevice.recognise(image)
                    if Task.isCancelled { throw TextRecognitionError.cancelled }
                    return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: text.isEmpty, fallbackReason: reason)
                }
            }
        }
        let text = try await onDevice.recognise(image)
        if Task.isCancelled { throw TextRecognitionError.cancelled }
        return TextRecognitionResult(
            text: text,
            characterCount: text.count,
            engine: .onDevice,
            isEmpty: text.isEmpty
        )
    }
}
