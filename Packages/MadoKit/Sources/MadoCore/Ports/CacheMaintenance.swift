import Foundation

/// Cache maintenance operations consumed by application state, independent of storage.
public protocol CacheMaintenance: Sendable {
    func sizeBytes() async throws -> Int64
    func clear() async throws
    func waitForPendingDeletions(onRegistered: (@Sendable () -> Void)?) async
    func deferredClearFailure() async -> String?
    func hasWriteFailure() async -> Bool
}
