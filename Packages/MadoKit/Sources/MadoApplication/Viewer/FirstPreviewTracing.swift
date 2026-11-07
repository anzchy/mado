import Foundation

public enum FirstPreviewOutcome: String, Sendable { case success, cancelled, failed }
@MainActor public protocol FirstPreviewTracing: AnyObject {
    func begin(_ id: UUID, fileURL: URL)
    func end(_ id: UUID, outcome: FirstPreviewOutcome)
}
