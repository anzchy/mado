import Foundation
import os
import MadoCore
import UniformTypeIdentifiers

/// One event stream and one root lease per AccessRootID while any subscriber of that root is live.
/// Start/stop transitions of a root run strictly one after another, so a stream never outlives its lease.
public final class WatchHub: FolderWatching, @unchecked Sendable {
    public static let debounceMilliseconds = 200
    public static let maxWaitMilliseconds = 1000
    private let access: any AccessLeasing
    private let source: any FolderEventSource
    private let scheduler: any WatchScheduling
    private let lock = NSLock()
    private var roots: [AccessRootID: Root] = [:]
    /// Paths stay out of the log; root IDs and error kinds are public so a folder that stops updating can be diagnosed.
    private let log = Logger(subsystem: "io.github.anzchy.mado", category: "watch")

    /// Mutable state below is guarded by the hub's lock.
    private final class Subscriber: @unchecked Sendable {
        let id = UUID(), folder: URL, path: [String], recursive: Bool, onChange: @Sendable () -> Void
        var pending = false, timer: (any WatchCancellable)?, windowStart: Int?, epoch = 0
        init(folder: URL, recursive: Bool, onChange: @escaping @Sendable () -> Void) {
            self.folder = folder; path = WatchHub.canonical(folder); self.recursive = recursive; self.onChange = onChange
        }
        /// `changed` nil means mustRescan. Ancestors, the folder itself and its (direct, unless recursive) contents are
        /// relevant, except below the folder where the scan skips hidden items and package contents.
        func isRelevant(_ changed: (path: [String], excluded: [Bool])?) -> Bool {
            guard let changed else { return true }
            let shared = min(changed.path.count, path.count)
            return changed.path.prefix(shared) == path.prefix(shared) && (recursive || changed.path.count <= path.count + 1)
                && !changed.excluded.dropFirst(path.count).contains(true)
        }
    }
    private final class Root: @unchecked Sendable {
        var subscribers: [UUID: Subscriber] = [:]
        var stream: (any FolderEventStream)?
        var lease: AccessLease?
        var preferredFolder: URL?
        var restartRequested = false
        var tail: Task<(any Error)?, Never>?, queued = 0
    }
    private struct Subscription: FolderWatchSubscription {
        let hub: WatchHub, root: Root, rootID: AccessRootID, id: UUID
        func cancel() async { await hub.remove(id, from: root, rootID) }
    }

    public init(access: any AccessLeasing, source: any FolderEventSource, scheduler: any WatchScheduling) {
        self.access = access; self.source = source; self.scheduler = scheduler
    }

    public func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
        onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription {
        let subscriber = Subscriber(folder: folder, recursive: recursive, onChange: onChange)
        let (root, transition, siblings) = lock.withLock { () -> (Root, Task<(any Error)?, Never>, [Subscriber]) in
            let root = roots[rootID] ?? Root()
            roots[rootID] = root
            let relocated = root.lease.map { !AccessBoundary.contains(folder, in: $0.url) } ?? false
            let siblings = relocated ? Array(root.subscribers.values) : []
            root.subscribers[subscriber.id] = subscriber
            if relocated {
                root.preferredFolder = folder
                root.restartRequested = true
            }
            return (root, enqueue(root, rootID), siblings)
        }
        I658ScanStartTiming.mark("WatchHub transition wait start")
        let transitionError = await transition.value
        I658ScanStartTiming.mark("WatchHub transition wait end")
        if let error = transitionError {
            await remove(subscriber.id, from: root, rootID)
            throw error
        }
        // Every old window must rebase its own folder URL after the shared stream moves.
        for sibling in siblings { sibling.onChange() }
        return Subscription(hub: self, root: root, rootID: rootID, id: subscriber.id)
    }

    /// Delivers immediately, outside the lock; a pending debounce window is cancelled and folded into this one delivery.
    public func reconcileAll() {
        let due = lock.withLock { roots.values.flatMap(\.subscribers.values).map { s in
            s.timer?.cancel(); s.timer = nil; s.windowStart = nil; s.epoch += 1; s.pending = false
            return s
        } }
        log.notice("FolderWatch reconcile subscribers=\(due.count, privacy: .public)")
        for subscriber in due { subscriber.onChange() }
    }

    private func remove(_ id: UUID, from root: Root, _ rootID: AccessRootID) async {
        let transition = lock.withLock { () -> Task<(any Error)?, Never>? in
            guard let subscriber = root.subscribers.removeValue(forKey: id) else { return nil }
            subscriber.timer?.cancel()
            return enqueue(root, rootID)
        }
        _ = await transition?.value
    }

    /// Caller holds the lock. Chains a transition after the root's previous one.
    private func enqueue(_ root: Root, _ rootID: AccessRootID) -> Task<(any Error)?, Never> {
        let previous = root.tail
        root.queued += 1
        let task = Task {
            _ = await previous?.value
            let error = await self.transition(root, rootID)
            self.lock.withLock { // An idle root with nothing queued leaves the map; its Subscriptions still hold it.
                root.queued -= 1
                if root.queued == 0, root.subscribers.isEmpty, root.stream == nil, self.roots[rootID] === root { self.roots[rootID] = nil }
            }
            return error
        }
        root.tail = task
        return task
    }

    private enum Step { case none, start(URL), stop(any FolderEventStream, AccessLease) }
    private func transition(_ root: Root, _ rootID: AccessRootID) async -> (any Error)? {
        let step = lock.withLock { () -> Step in
            if root.subscribers.isEmpty || root.restartRequested,
               let stream = root.stream, let lease = root.lease {
                root.stream = nil; root.lease = nil
                root.restartRequested = false
                return .stop(stream, lease)
            }
            guard !root.subscribers.isEmpty else { root.preferredFolder = nil; return .none }
            guard root.stream == nil, let folder = root.preferredFolder ?? root.subscribers.values.first?.folder else { return .none }
            return .start(folder)
        }
        switch step {
        case .none: return nil
        case .stop(let stream, let lease):
            stream.stop()
            log.notice("FolderWatch stop root=\(rootID.rawValue.uuidString, privacy: .public)")
            await access.release(lease)
            return await transition(root, rootID)
        case .start(let folder):
            let lease: AccessLease
            do { lease = try await access.acquire(.root(rootID, file: folder)) } catch {
                log.error("FolderWatch lease failed root=\(rootID.rawValue.uuidString, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
                return error
            }
            I658ScanStartTiming.mark("WatchHub lease acquired")
            guard lock.withLock({ !root.subscribers.isEmpty }) else { await access.release(lease); return nil }
            let stream: any FolderEventStream
            do { stream = try source.start(watching: lease.url) { [weak self] hints in self?.deliver(hints, to: root) } } catch {
                log.error("FolderWatch stream failed root=\(rootID.rawValue.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                await access.release(lease)
                return error
            }
            I658ScanStartTiming.mark("FSEventSource start returned")
            lock.withLock { root.stream = stream; root.lease = lease }
            log.notice("FolderWatch start root=\(rootID.rawValue.uuidString, privacy: .public)")
            return nil
        }
    }

    /// Path components after resolving symlinks on the deepest existing ancestor, so deleted paths
    /// spelled `/private/var/...` and `/var/...` compare equal.
    static func canonical(_ url: URL) -> [String] {
        var head = url.standardizedFileURL, tail: [String] = []
        while head.pathComponents.count > 1, !FileManager.default.fileExists(atPath: head.path) {
            tail.insert(head.lastPathComponent, at: 0); head.deleteLastPathComponent()
        }
        return head.resolvingSymlinksInPath().pathComponents + tail
    }

    /// Mirrors FolderBrowser's `.skipsHiddenFiles` and `.skipsPackageDescendants` by name, so deleted paths judge alike.
    static func isExcluded(_ component: String) -> Bool {
        let ext = (component as NSString).pathExtension
        return component.hasPrefix(".") || !ext.isEmpty && UTType(filenameExtension: ext, conformingTo: .package)?.isDynamic == false
    }

    private func deliver(_ hints: [FolderChangeHint], to root: Root) {
        let paths = hints.map { hint -> (path: [String], excluded: [Bool])? in
            guard case .changed(let url) = hint else { return nil }
            let path = Self.canonical(url)
            return (path, path.map(Self.isExcluded))
        }
        if paths.contains(where: { $0 == nil }) { log.notice("FolderWatch mustRescan") }
        lock.withLock {
            let now = scheduler.nowMilliseconds
            for subscriber in root.subscribers.values {
                guard paths.contains(where: subscriber.isRelevant) else { continue }
                subscriber.pending = true
                let start = subscriber.windowStart ?? now
                subscriber.windowStart = start; subscriber.epoch += 1
                subscriber.timer?.cancel()
                subscriber.timer = scheduler.schedule(afterMilliseconds: min(now + Self.debounceMilliseconds,
                    start + Self.maxWaitMilliseconds) - now) { [weak self, epoch = subscriber.epoch] in
                    self?.flush(subscriber, of: root, epoch: epoch)
                }
            }
        }
    }

    private func flush(_ subscriber: Subscriber, of root: Root, epoch: Int) {
        let due = lock.withLock { () -> Bool in
            guard subscriber.epoch == epoch, root.subscribers[subscriber.id] === subscriber else { return false }
            subscriber.timer = nil; subscriber.windowStart = nil
            defer { subscriber.pending = false }
            return subscriber.pending
        }
        if due { subscriber.onChange() }
    }
}
