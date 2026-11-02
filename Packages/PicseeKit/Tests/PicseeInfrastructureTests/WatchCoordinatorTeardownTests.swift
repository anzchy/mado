import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

/// Forwards to the hub, but holds each subscribe until `open()` while `closed`.
private final class GatedWatcher: FolderWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let hub: WatchHub
    private var closed = false, waiters: [CheckedContinuation<Void, Never>] = []
    init(_ hub: WatchHub) { self.hub = hub }
    func close() { lock.withLock { closed = true } }
    func open() { for waiter in lock.withLock({ closed = false; defer { waiters = [] }; return waiters }) { waiter.resume() } }
    var waiting: Int { lock.withLock { waiters.count } }
    func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
        onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription {
        await withCheckedContinuation { continuation in
            let held = lock.withLock { closed ? { waiters.append(continuation); return true }() : false }
            if !held { continuation.resume() }
        }
        return try await hub.subscribe(rootID: rootID, folder: folder, recursive: recursive, onChange: onChange)
    }
    func reconcileAll() { hub.reconcileAll() }
}

/// A fresh fixture per section, so one section's leak cannot hide or fail another's.
@MainActor private func section() async throws -> (WatchedCoordinator, AccessRootID) {
    let w = try await WatchedCoordinator(files: ["F/a.png", "H/h.png"], folders: ["root/F", "root/H", "other/K"])
    FileManager.default.createFile(atPath: w.f.url("other/K/k.png").path, contents: Data())
    return (w, try await w.f.access.grant(folder: w.f.url("other")))
}

@MainActor private func make(_ w: WatchedCoordinator, _ watcher: any FolderWatching) -> FolderScanCoordinator {
    FolderScanCoordinator(access: w.f.access, scanner: FolderBrowser(), watcher: watcher)
}

@MainActor private func released(_ w: WatchedCoordinator, _ step: String, fileID: String = #fileID, line: Int = #line) async throws {
    try await waitUntil(step, fileID: fileID, line: line) { w.f.source.active == 0 && w.scopeBalanced }
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorCancelsItsSubscriptionsWhenEndedOrReleased() async throws {
    // end() and release in the same turn: nothing waits on the released coordinator to cancel.
    do {
        let (w, _) = try await section(); defer { w.f.remove() }
        var ended: FolderScanCoordinator? = make(w, w.f.hub)
        try await ended?.begin(folder: w.url("F"), rootID: w.rootID).value
        #expect(w.f.source.active == 1)
        ended?.end(); ended = nil
        try await released(w, "end() then release")
    }
    // Released without end(): teardown cancels the live watch.
    do {
        let (w, _) = try await section(); defer { w.f.remove() }
        var dropped: FolderScanCoordinator? = make(w, w.f.hub)
        try await dropped?.begin(folder: w.url("F"), rootID: w.rootID).value
        #expect(w.f.source.active == 1)
        dropped = nil
        try await released(w, "release without end()")
    }
    // A folder switch inside one root keeps the shared stream; the old subscription goes once the new one exists.
    do {
        let (w, _) = try await section(); defer { w.f.remove() }
        let stable = make(w, w.f.hub)
        try await stable.begin(folder: w.url("F"), rootID: w.rootID).value
        try await stable.begin(folder: w.url("H"), rootID: w.rootID).value
        #expect(w.f.source.starts == 1 && w.f.source.stops == 0 && w.f.source.active == 1)
        stable.end()
        try await released(w, "folder switch then end()")
    }
    // Switching roots while the new subscribe is held, then releasing: both roots end up stopped.
    do {
        let (w, other) = try await section(); defer { w.f.remove() }
        let gate = GatedWatcher(w.f.hub); defer { gate.open() }
        var switching: FolderScanCoordinator? = make(w, gate)
        try await switching?.begin(folder: w.url("F"), rootID: w.rootID).value
        gate.close()
        let pending = switching?.begin(folder: w.f.url("other/K"), rootID: other)
        try await waitUntil { gate.waiting == 1 }
        switching = nil
        gate.open()
        _ = try? await pending?.value
        try await released(w, "root switch held, then release")
    }
}
