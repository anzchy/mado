import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

/// Thread-safe record of every hint batch a real stream delivers.
private final class HintRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[FolderChangeHint]] = []
    var count: Int { lock.withLock { batches.count } }
    var changedPaths: [String] {
        lock.withLock { batches.flatMap { $0 } }.compactMap { if case .changed(let url) = $0 { canonicalPath(url) } else { nil } }
    }
    var sink: @Sendable ([FolderChangeHint]) -> Void { { [self] hints in lock.withLock { batches.append(hints) } } }
}

private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fires: [ContinuousClock.Instant] = []
    var count: Int { lock.withLock { fires.count } }
    var first: ContinuousClock.Instant? { lock.withLock { fires.first } }
    var action: @Sendable () -> Void { { [self] in let now = ContinuousClock.now; lock.withLock { fires.append(now) } } }
}

private final class StreamHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (any FolderEventStream)?
    var stream: (any FolderEventStream)? { lock.withLock { held } }
    func set(_ stream: any FolderEventStream) { lock.withLock { held = stream } }
}

private func makeTempDir(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test(.timeLimit(.minutes(3))) @MainActor func realFSEventSourceDeliversWritesUntilStopAndRefreshesCoordinator() async throws {
    // Part 1: a real write reaches stream A; after A.stop() returns, A sees nothing more, with sentinel B ending the wait.
    let dir = try makeTempDir("fsevents"); defer { try? FileManager.default.removeItem(at: dir) }
    let a = HintRecorder(), b = HintRecorder()
    let streamA = try FSEventSource().start(watching: dir, onHints: a.sink)
    let x = dir.appendingPathComponent("x.png")
    FileManager.default.createFile(atPath: x.path, contents: Data([1]))
    try await waitUntil { a.changedPaths.contains(canonicalPath(x)) }
    streamA.stop()
    streamA.stop() // idempotent
    let aAtStop = a.count
    let streamB = try FSEventSource().start(watching: dir, onHints: b.sink)
    let y = dir.appendingPathComponent("y.png")
    FileManager.default.createFile(atPath: y.path, contents: Data([1]))
    try await waitUntil { b.changedPaths.contains(canonicalPath(y)) }
    #expect(a.count == aAtStop)
    streamB.stop()

    // Part 1b: stop() called from inside the stream's own callback returns (no deadlock) and ends later callbacks.
    let c = HintRecorder(), d = HintRecorder(), holder = StreamHolder()
    let cSink = c.sink
    holder.set(try FSEventSource().start(watching: dir) { hints in cSink(hints); holder.stream?.stop() })
    let z1 = dir.appendingPathComponent("z1.png")
    FileManager.default.createFile(atPath: z1.path, contents: Data([1]))
    try await waitUntil { c.count >= 1 }
    let streamD = try FSEventSource().start(watching: dir, onHints: d.sink)
    let z2 = dir.appendingPathComponent("z2.png")
    FileManager.default.createFile(atPath: z2.path, contents: Data([1]))
    try await waitUntil { d.changedPaths.contains(canonicalPath(z2)) }
    #expect(c.count == 1)
    streamD.stop()

    // Part 2: real FileAccess, real WatchHub over real FSEvents and the production scheduler, real FolderBrowser.
    let base = try makeTempDir("fsevents-e2e"); defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appendingPathComponent("root/F")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: folder.appendingPathComponent("a.png").path, contents: Data())
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: base.appendingPathComponent("store.json")), buildSHA: "test")
    let rootID = try await access.grant(folder: base.appendingPathComponent("root"))
    let hub = WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler())
    let host = RecordingScanHost()
    let coordinator = FolderScanCoordinator(access: access, scanner: FolderBrowser(), watcher: hub)
    coordinator.host = host
    try await coordinator.begin(folder: folder, rootID: rootID).value
    #expect(coordinator.snapshot?.entries.map(\.relativePath) == ["F/a.png"])
    FileManager.default.createFile(atPath: folder.appendingPathComponent("new.png").path, contents: Data([1]))
    try await waitUntil {
        coordinator.snapshot?.entries.map(\.relativePath).contains("F/new.png") == true }
    #expect(host.didStart == 1)
    coordinator.end()
    try await waitUntil { let counts = scope.counts; return counts[0] == counts[1] }
}

@Test(.timeLimit(.minutes(3))) func dispatchWatchSchedulerFiresWithinRealTimeBound() async throws {
    #expect(FSEventSource.latency <= 0.1)
    let scheduler = DispatchWatchScheduler()
    let x = FireCounter(), y = FireCounter(), z = FireCounter()
    let startMilliseconds = scheduler.nowMilliseconds
    let start = ContinuousClock.now
    _ = scheduler.schedule(afterMilliseconds: 200, x.action)
    // The time limit guards a missing callback; CI has delayed a 200 ms item by over 20 s.
    #expect(try await poll { x.count >= 1 })
    let elapsed = (x.first ?? start) - start
    // Dispatch is allowed to run late under load; only an early callback violates the delay.
    #expect(elapsed >= .milliseconds(200))
    #expect(scheduler.nowMilliseconds - startMilliseconds >= 200)
    scheduler.schedule(afterMilliseconds: 100, y.action).cancel()
    let zStart = ContinuousClock.now
    _ = scheduler.schedule(afterMilliseconds: 300, z.action)
    #expect(try await poll { z.count == 1 })
    #expect((z.first ?? zStart) - zStart >= .milliseconds(300))
    #expect(y.count == 0)
    #expect(x.count == 1)
}
