import Foundation

/// Why an explicit Recognise Text did not try Cloud Recognition: the first unmet condition, in the order the service
/// checks them (switch, consent, network, keys).
public enum CloudSkipReason: String, Sendable, Equatable { case disabled, consentNotGiven, offline, noKeys }

/// What one explicit Recognise Text did about Cloud Recognition (#689b dev1). The App logs it, so a silent fallback
/// on a device names its reason. It never carries the keys, the token or the image.
public enum CloudRecognitionOutcome: Sendable, Equatable {
    case cloud
    case skipped(CloudSkipReason)
    case fallback(CloudFallbackReason, TextRecognitionError)

    /// One public log line: the engine used and, for On-device Recognition, why Baidu was not used.
    public var logMessage: String {
        switch self {
        case .cloud: "engine=cloud"
        case .skipped(let reason): "engine=onDevice skipped=\(reason.rawValue)"
        case .fallback(let reason, let error): "engine=onDevice fallback=\(reason.name) error=\(error.logName)"
        }
    }
}

extension CloudFallbackReason {
    var name: String {
        switch self {
        case .auth: "auth"
        case .quota: "quota"
        case .offline: "offline"
        case .failure: "failure"
        }
    }
}

extension TextRecognitionError {
    var logName: String {
        switch self {
        case .invalidImage: "invalidImage"
        case .cancelled: "cancelled"
        case .recognitionFailed(let domain, let code): "recognitionFailed(\(domain) \(code))"
        case .cloudAuth: "cloudAuth"
        case .cloudQuota: "cloudQuota"
        case .cloudOffline: "cloudOffline"
        case .cloudFailure: "cloudFailure"
        case .cloudImageTooLarge: "cloudImageTooLarge"
        }
    }
}
