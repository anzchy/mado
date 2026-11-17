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

/// Why one Baidu attempt failed, as Baidu or the network said it (#689b dev1): the stage, the HTTP status, Baidu's
/// numeric error_code and its message (or the OAuth error and description), or the transport error's code. It never
/// carries the keys, the access token, the image or a request URL; the provider redacts the keys and the token from
/// Baidu's own message.
public struct CloudFailureDetail: Sendable, Equatable {
    public enum Stage: String, Sendable { case token, recognition }
    public let stage: Stage
    public let httpStatus: Int?
    public let errorCode: Int?
    public let errorMessage: String?
    public let transportError: String?

    public init(stage: Stage, httpStatus: Int? = nil, errorCode: Int? = nil, errorMessage: String? = nil,
                transportError: String? = nil) {
        self.stage = stage; self.httpStatus = httpStatus; self.errorCode = errorCode
        self.errorMessage = errorMessage; self.transportError = transportError
    }

    /// One public log line: `baidu stage=… http=… error_code=… error_msg="…"` or `… transport=…`.
    public var logMessage: String {
        var parts = ["baidu", "stage=\(stage.rawValue)"]
        if let httpStatus { parts.append("http=\(httpStatus)") }
        if let errorCode { parts.append("error_code=\(errorCode)") }
        if let errorMessage { parts.append("error_msg=\"\(errorMessage)\"") }
        if let transportError { parts.append("transport=\(transportError)") }
        return parts.joined(separator: " ")
    }
}
