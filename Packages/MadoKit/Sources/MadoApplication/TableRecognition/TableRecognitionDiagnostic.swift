import Foundation
import OSLog

/// Local-only measurements of one sent table request. No request or response payload belongs here.
public struct TableRecognitionDiagnostic: Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let durationMilliseconds: Int
    public let errorClass: TableRecognitionFailure?

    init(promptTokens: Int?, completionTokens: Int?, durationMilliseconds: Int,
         errorClass: TableRecognitionFailure?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.durationMilliseconds = durationMilliseconds
        self.errorClass = errorClass
    }

    /// Fixed fields only: response text, image bytes, keys and endpoint addresses never enter this value.
    public var logMessage: String {
        let prompt = promptTokens.map(String.init) ?? "unknown"
        let completion = completionTokens.map(String.init) ?? "unknown"
        return "table-recognition prompt_tokens=\(prompt) completion_tokens=\(completion) duration_ms=\(durationMilliseconds) error=\(errorClass?.diagnosticName ?? "none")"
    }

    private static let logger = Logger(subsystem: "io.github.anzchy.mado", category: "table-recognition")

    public static func record(_ diagnostic: TableRecognitionDiagnostic) {
        logger.notice("\(diagnostic.logMessage, privacy: .public)")
    }

    static func make(response: HTTPResponse?, durationMilliseconds: Int,
                     errorClass: TableRecognitionFailure?) -> TableRecognitionDiagnostic {
        let usage = response.flatMap { try? JSONDecoder().decode(UsageEnvelope.self, from: $0.body).usage }
        return TableRecognitionDiagnostic(
            promptTokens: usage?.promptTokens.flatMap { $0 >= 0 ? $0 : nil },
            completionTokens: usage?.completionTokens.flatMap { $0 >= 0 ? $0 : nil },
            durationMilliseconds: durationMilliseconds,
            errorClass: errorClass)
    }

    private struct UsageEnvelope: Decodable {
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens", completionTokens = "completion_tokens" }
        }
        let usage: Usage?
    }
}

private extension TableRecognitionFailure {
    var diagnosticName: String {
        switch self {
        case .keyRejected: "keyRejected"
        case .addressUnreachable: "addressUnreachable"
        case .modelCannotReadImages: "modelCannotReadImages"
        case .offline: "offline"
        case .quotaOrBalance: "quotaOrBalance"
        case .tooLarge: "tooLarge"
        case .noTable: "noTable"
        case .incomplete: "incomplete"
        case .other: "other"
        }
    }
}
