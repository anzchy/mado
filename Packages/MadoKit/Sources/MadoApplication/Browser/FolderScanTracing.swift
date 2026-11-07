import Foundation

public enum FolderScanOutcome: String, Equatable, Sendable { case complete, cancelled, replaced, failed }

/// Completed counts describe navigable unique images after identity projection.
/// Native adapters keep folder paths private and never log image names.
@MainActor public protocol FolderScanTracing: AnyObject {
    func begin(generation: UInt64, folderURL: URL)
    func firstBatch(count: Int, generation: UInt64)
    func complete(count: Int, generation: UInt64)
    func failure(_ error: any Error, generation: UInt64)
    func end(outcome: FolderScanOutcome, generation: UInt64)
}

public extension FolderScanTracing {
    func failure(_ error: any Error, generation: UInt64) { }
}
