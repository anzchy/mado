import Foundation

public enum FolderChangeHint: Equatable, Sendable { case changed(URL), mustRescan }
public enum FolderWatchError: Error, Equatable, Sendable { case streamCreateFailed, streamStartRefused }
public protocol FolderEventStream: Sendable { func stop() }
/// Delivers hints on an arbitrary thread until stop() returns; throws when no stream is running.
public protocol FolderEventSource: Sendable {
    func start(watching url: URL, onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) throws -> any FolderEventStream
}
public protocol WatchCancellable: Sendable { func cancel() }
/// Monotonic milliseconds; actions run on an arbitrary thread.
public protocol WatchScheduling: Sendable {
    var nowMilliseconds: Int { get }
    func schedule(afterMilliseconds: Int, _ action: @escaping @Sendable () -> Void) -> any WatchCancellable
}
public protocol FolderWatchSubscription: Sendable { func cancel() async }
public protocol FolderWatching: Sendable {
    /// Leases `.root(rootID, file: folder)` while any subscriber of that root is live; onChange fires once per window
    /// with a relevant hint. Throws, holding nothing, when the lease or the stream fails.
    func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
        onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription
    /// Foreground reconcile: one immediate onChange to every live subscriber.
    func reconcileAll()
}
