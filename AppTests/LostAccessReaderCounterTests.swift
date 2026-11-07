import Foundation
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

private struct T229CounterAdapter: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}
private actor T229CounterMounts: DiskMountPort {
    func mountedVolumes() -> [AccessProbeVolume] { [] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { _ in } }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229StaleReaderFailureCannotLoseExplicitReplacementGrant() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let old = base.appendingPathComponent("Old", isDirectory: true)
    let selected = base.appendingPathComponent("Selected", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let adapter = T229CounterAdapter()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-counter")
    let id = try await files.grant(folder: old)
    let monitor = AccessMonitor(files: files, mounts: T229CounterMounts())
    await monitor.start()
    let stale = monitor.state.stamp(for: id)
    _ = try await files.reconnect(id, folder: selected)
    await monitor.reauthorize(id)
    try FileManager.default.removeItem(at: selected)
    await monitor.reportReadFailure(id, from: stale)
    #expect(monitor.state.snapshot(for: id)?.availability == .readable)
    #expect(monitor.state.snapshot(for: id)?.counter == 1)
    await monitor.reportReadFailure(id, from: monitor.state.stamp(for: id))
    #expect(monitor.state.snapshot(for: id)?.availability == .lost(.unknown))
    #expect(monitor.state.snapshot(for: id)?.counter == 2)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229CancelledReaderRootCheckDoesNotRevokeReadableGrant() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let adapter = T229CounterAdapter()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-cancelled")
    let id = try await files.grant(folder: root)
    let monitor = AccessMonitor(files: files, mounts: T229CounterMounts())
    await monitor.start()
    let stamp = monitor.state.stamp(for: id)
    let check = Task { await monitor.reportReadFailure(id, from: stamp) }
    check.cancel()
    await check.value
    #expect(monitor.state.snapshot(for: id)?.availability == .readable)
    #expect(monitor.state.snapshot(for: id)?.counter == 0)
}

private actor T229ChangingCounterMounts: DiskMountPort {
    private var volumes = [AccessProbeVolume(uuid: "111", url: nil, name: "Disk")]
    private var continuation: AsyncStream<DiskMountEvent>.Continuation?
    func mountedVolumes() -> [AccessProbeVolume] { volumes }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { continuation = $0 } }
    func unmount() {
        volumes = []
        continuation?.yield(.unmounted(AccessProbeVolume(uuid: "111", url: nil, name: "Disk")))
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229ExplicitGrantCompletionCannotMaskNewerUnmount() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let adapter = T229CounterAdapter()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-grant-race",
        bookmarkVolume: { _ in AccessProbeVolume(uuid: "111", url: nil, name: "Disk") },
        resolvedVolumeUUID: { _ in "111" })
    let id = try await files.grant(folder: root)
    let mounts = T229ChangingCounterMounts()
    let monitor = AccessMonitor(files: files, mounts: mounts)
    await monitor.start()
    await mounts.unmount()
    while monitor.state.snapshot(for: id)?.availability != .lost(.diskNotConnected) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(monitor.state.snapshot(for: id)?.availability == .lost(.diskNotConnected))
    await monitor.reauthorize(id)
    #expect(monitor.state.snapshot(for: id)?.availability == .lost(.diskNotConnected))
    #expect(monitor.state.permit(for: id) == nil)
}

private final class T229ReplacingGrantAdapter: SecurityScope, BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var volume = "111"
    var currentVolume: String { lock.withLock { volume } }
    func replaceVolume() { lock.withLock { volume = "222" } }
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data("\(currentVolume)|\(url.path)".utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let path = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1)[1]
        return ResolvedBookmark(url: URL(fileURLWithPath: String(path)), stale: false)
    }
}
private actor T229PausedGrantMounts: DiskMountPort {
    private var pauseNext = false
    private(set) var paused = false
    private var waiting: CheckedContinuation<[AccessProbeVolume], Never>?
    private var volumes: [AccessProbeVolume] {
        [AccessProbeVolume(uuid: "111", url: nil, name: "Old"), AccessProbeVolume(uuid: "222", url: nil, name: "New")]
    }
    func mountedVolumes() async -> [AccessProbeVolume] {
        if pauseNext {
            pauseNext = false; paused = true
            return await withCheckedContinuation { waiting = $0 }
        }
        return volumes
    }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { _ in } }
    func pause() { pauseNext = true }
    func resume() { pauseNext = false; waiting?.resume(returning: volumes); waiting = nil }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229ReauthorizationCannotBindOldUUIDToNewlyVerifiedReplacementGrant() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("SameMountPath", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let adapter = T229ReplacingGrantAdapter()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-replaced-grant",
        bookmarkVolume: { data in
            let uuid = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).first.map(String.init)
            return AccessProbeVolume(uuid: uuid, url: nil, name: "Disk")
        }, resolvedVolumeUUID: { _ in adapter.currentVolume })
    let id = try await files.grant(folder: root)
    let mounts = T229PausedGrantMounts()
    let monitor = AccessMonitor(files: files, mounts: mounts)
    await monitor.start()
    await mounts.pause()
    let pending = Task { await monitor.reauthorize(id) }
    while !(await mounts.paused) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await mounts.paused)
    adapter.replaceVolume()
    _ = try await files.reconnect(id, folder: root)
    await mounts.resume()
    await pending.value
    let snapshot = try #require(monitor.state.snapshot(for: id))
    #expect(snapshot.volumeUUID == "222" || snapshot.availability != .readable)
}

private actor T229FinalEnumerationMounts: DiskMountPort {
    private var readsBeforePause: Int?
    private(set) var paused = false
    private var waiting: CheckedContinuation<[AccessProbeVolume], Never>?
    private var volumes: [AccessProbeVolume] {
        [AccessProbeVolume(uuid: "111", url: nil, name: "Old"), AccessProbeVolume(uuid: "222", url: nil, name: "New")]
    }
    func mountedVolumes() async -> [AccessProbeVolume] {
        if let remaining = readsBeforePause {
            if remaining == 0 {
                readsBeforePause = nil; paused = true
                return await withCheckedContinuation { waiting = $0 }
            }
            readsBeforePause = remaining - 1
        }
        return volumes
    }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { _ in } }
    // The first enumeration verifies the old saved root. Hold the subsequent
    // enumeration, after the monitor has compared its saved bookmark bytes.
    func pauseFinalEnumeration() { readsBeforePause = 1 }
    func resume() { readsBeforePause = nil; waiting?.resume(returning: volumes); waiting = nil }
}

@MainActor private func t229CheckFinalGrantEnumerationRace(startingLost: Bool) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("SameMountPath", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let adapter = T229ReplacingGrantAdapter()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-final-grant-race",
        bookmarkVolume: { data in
            let uuid = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).first.map(String.init)
            return AccessProbeVolume(uuid: uuid, url: nil, name: "Disk")
        }, resolvedVolumeUUID: { _ in adapter.currentVolume })
    let id = try await files.grant(folder: root)
    let mounts = T229FinalEnumerationMounts()
    let monitor = AccessMonitor(files: files, mounts: mounts)
    await monitor.start()
    if startingLost {
        #expect(monitor.state.reportRootFailure(id, cause: .unknown, from: monitor.state.stamp(for: id)))
    }
    var recoveryEvents: [AccessStateChange] = []
    let observer = monitor.state.observe { change in
        if case .recovered = change { recoveryEvents.append(change) }
    }
    defer { monitor.state.removeObserver(observer) }
    await mounts.pauseFinalEnumeration()
    let pending = Task { await monitor.reauthorize(id) }
    while !(await mounts.paused) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await mounts.paused)
    adapter.replaceVolume()
    _ = try await files.reconnect(id, folder: root)
    await mounts.resume()
    await pending.value
    #expect(monitor.state.snapshot(for: id)?.availability == .lost(.unknown))
    #expect(monitor.state.permit(for: id) == nil)
    #expect(recoveryEvents.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229FinalMountAwaitCannotRecoverSupersededLostGrant() async throws {
    try await t229CheckFinalGrantEnumerationRace(startingLost: true)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229FinalMountAwaitCannotKeepSupersededReadableGrant() async throws {
    try await t229CheckFinalGrantEnumerationRace(startingLost: false)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229CancelledExplicitNoUUIDReauthorizationStillVerifiesUnreadableRoot() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let adapter = T229CounterAdapter()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-cancelled-grant")
    let id = try await files.grant(folder: root)
    let monitor = AccessMonitor(files: files, mounts: T229CounterMounts())
    await monitor.start()
    #expect(monitor.state.reportRootFailure(id, cause: .unknown, from: monitor.state.stamp(for: id)))
    try FileManager.default.removeItem(at: root)
    var recoveries: [AccessStateChange] = []
    let observer = monitor.state.observe { change in
        if case .recovered = change { recoveries.append(change) }
    }
    defer { monitor.state.removeObserver(observer) }
    let pending = Task { await monitor.reauthorize(id) }
    pending.cancel()
    await pending.value
    #expect(monitor.state.snapshot(for: id)?.availability == .lost(.unknown))
    #expect(monitor.state.permit(for: id) == nil)
    #expect(recoveries.isEmpty)
}
