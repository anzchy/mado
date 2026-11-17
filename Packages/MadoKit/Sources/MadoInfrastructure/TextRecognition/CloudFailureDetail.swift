import Foundation

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
