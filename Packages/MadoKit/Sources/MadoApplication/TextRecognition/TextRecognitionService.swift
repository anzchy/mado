import Foundation

public enum TextRecognitionIntent: Sendable {
    case selection
    case selectOnImage
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
    public let lines: [TextRecognitionLine]

    public init(text: String, characterCount: Int, engine: TextRecognitionEngine, isEmpty: Bool, fallbackReason: CloudFallbackReason? = nil, lines: [TextRecognitionLine] = []) {
        self.text = text
        self.characterCount = characterCount
        self.engine = engine
        self.isEmpty = isEmpty
        self.fallbackReason = fallbackReason
        self.lines = lines
    }
}

/// Vision coordinates: origin at the bottom left of the displayed image, in 0...1.
public struct TextRecognitionLine: Sendable {
    public let text: String
    public let box: CGRect
    /// One box per Swift Character when Vision can provide it; empty means uniform fallback.
    public let characterBoxes: [CGRect]

    public init(text: String, box: CGRect, characterBoxes: [CGRect] = []) {
        self.text = text; self.box = box; self.characterBoxes = characterBoxes
    }
}

public protocol OnDeviceTextRecognitionProviding: Sendable {
    func recognise(_ image: Data) async throws(TextRecognitionError) -> String
    func recogniseLines(_ image: Data) async throws(TextRecognitionError) -> [TextRecognitionLine]
}

public extension OnDeviceTextRecognitionProviding {
    func recogniseLines(_ image: Data) async throws(TextRecognitionError) -> [TextRecognitionLine] {
        _ = try await recognise(image)
        return []
    }
}

public protocol CloudTextRecognitionProviding: Sendable {
    func recognise(_ image: Data, credentials: CloudCredentials) async throws(TextRecognitionError) -> String
}

public struct TextRecognitionService: Sendable {
    private let onDevice: any OnDeviceTextRecognitionProviding
    private let settings: (any CloudRecognitionSettings)?
    private let credentialStore: (any CloudCredentialStore)?
    private let cloud: (any CloudTextRecognitionProviding)?
    private let report: (@Sendable (CloudRecognitionOutcome) -> Void)?

    /// `report` hears, once per explicit run with a cloud provider, whether Baidu answered, was skipped or failed
    /// (#689b dev1). It is called only once the engine it names has delivered and the run is still current (#689b
    /// dev2): selection runs, cancelled runs and runs whose on-device engine fails report nothing.
    public init(onDevice: any OnDeviceTextRecognitionProviding, settings: (any CloudRecognitionSettings)? = nil,
                credentialStore: (any CloudCredentialStore)? = nil, cloud: (any CloudTextRecognitionProviding)? = nil,
                report: (@Sendable (CloudRecognitionOutcome) -> Void)? = nil) {
        self.onDevice = onDevice
        self.settings = settings; self.credentialStore = credentialStore; self.cloud = cloud
        self.report = report
    }

    public func recognise(_ image: Data, intent: TextRecognitionIntent) async throws(TextRecognitionError) -> TextRecognitionResult {
        if Task.isCancelled { throw TextRecognitionError.cancelled }
        if case .selectOnImage = intent {
            let lines = try await onDevice.recogniseLines(image)
            if Task.isCancelled { throw TextRecognitionError.cancelled }
            let text = lines.map(\.text).joined(separator: "\n")
            return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice,
                                         isEmpty: text.isEmpty, lines: lines)
        }
        var outcome: CloudRecognitionOutcome?
        if case .explicit = intent, let settings, let credentialStore, let cloud {
            switch await cloudChoice(settings: settings, store: credentialStore) {
            case .skip(let reason):
                outcome = .skipped(reason)
            case .cloud(let credentials):
                do throws(TextRecognitionError) {
                    let text = try await cloud.recognise(image, credentials: credentials)
                    if Task.isCancelled { throw TextRecognitionError.cancelled }
                    report?(.cloud)
                    return TextRecognitionResult(text: text, characterCount: text.count, engine: .cloud, isEmpty: text.isEmpty)
                } catch {
                    if Task.isCancelled || error == .cancelled { throw TextRecognitionError.cancelled }
                    let reason: CloudFallbackReason = switch error {
                    case .cloudAuth: .auth
                    case .cloudQuota: .quota
                    case .cloudOffline: .offline
                    default: .failure
                    }
                    let text = try await onDevice.recognise(image)
                    if Task.isCancelled { throw TextRecognitionError.cancelled }
                    report?(.fallback(reason, error))
                    return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: text.isEmpty, fallbackReason: reason)
                }
            }
        }
        let text = try await onDevice.recognise(image)
        if Task.isCancelled { throw TextRecognitionError.cancelled }
        if let outcome { report?(outcome) }
        return TextRecognitionResult(
            text: text,
            characterCount: text.count,
            engine: .onDevice,
            isEmpty: text.isEmpty
        )
    }

    /// The keys when every condition allows Baidu, or the first unmet condition.
    private enum CloudChoice { case cloud(CloudCredentials), skip(CloudSkipReason) }
    private func cloudChoice(settings: any CloudRecognitionSettings, store: any CloudCredentialStore) async -> CloudChoice {
        let options = await settings.options()
        guard options.enabled else { return .skip(.disabled) }
        guard case .granted = options.consent else { return .skip(.consentNotGiven) }
        guard options.online else { return .skip(.offline) }
        guard let credentials = await store.credentials(), !credentials.apiKey.isEmpty,
              !credentials.secretKey.isEmpty else { return .skip(.noKeys) }
        return .cloud(credentials)
    }
}
