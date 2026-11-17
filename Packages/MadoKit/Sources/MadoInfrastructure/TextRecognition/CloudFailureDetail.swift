import Foundation

/// Why one Baidu attempt failed (#689b dev1, dev2): the stage, the HTTP status, Baidu's numeric error_code, a fixed
/// reason from `Reason`, or the transport error's code. It holds only these bounded facts: no text from the server
/// (Baidu's error_msg, the OAuth error_description), no keys, no access token, no image and no request URL.
public struct CloudFailureDetail: Sendable, Equatable {
    public enum Stage: String, Sendable { case token, recognition }
    /// The closed allowlist of reasons: Baidu's error_code bucket, an RFC 6749 token error name, or a local shape
    /// failure. Anything else Baidu sends becomes `other`.
    public enum Reason: String, Sendable, CaseIterable {
        case permission, quota, auth, other
        case invalidRequest = "invalid_request", invalidClient = "invalid_client", invalidGrant = "invalid_grant"
        case unauthorizedClient = "unauthorized_client", unsupportedGrantType = "unsupported_grant_type"
        case invalidScope = "invalid_scope"
        case unreadableResponse = "unreadable_response", noWordsResult = "no_words_result"
        case noAccessToken = "no_access_token"
    }
    public let stage: Stage
    public let httpStatus: Int?
    public let errorCode: Int?
    public let reason: Reason?
    public let transportError: String?

    public init(stage: Stage, httpStatus: Int? = nil, errorCode: Int? = nil, reason: Reason? = nil,
                transportError: String? = nil) {
        self.stage = stage; self.httpStatus = httpStatus; self.errorCode = errorCode; self.reason = reason
        self.transportError = transportError
    }

    /// One public log line: `baidu stage=… http=… error_code=… reason=…` or `baidu stage=… transport=…`.
    public var logMessage: String {
        var parts = ["baidu", "stage=\(stage.rawValue)"]
        if let httpStatus { parts.append("http=\(httpStatus)") }
        if let errorCode { parts.append("error_code=\(errorCode)") }
        if let reason { parts.append("reason=\(reason.rawValue)") }
        if let transportError { parts.append("transport=\(transportError)") }
        return parts.joined(separator: " ")
    }
}
