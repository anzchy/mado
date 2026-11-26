import Foundation

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

    public var logMessage: String { "" }
}
