import Foundation
import PicseeCore
@testable import PicseeInfrastructure

func canonicalPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

/// Fake event source keyed by canonical path; `emit` reaches only streams not yet stopped.
final class FakeFolderEventSource: FolderEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private let scopeCounts: @Sendable () -> [Int]
    private var handlers: [String: [UUID: @Sendable ([FolderChangeHint]) -> Void]] = [:]
    private var state = (starts: 0, stops: 0, active: 0, maxActive: 0, refusals: 0, refused: 0)
    private var started: [String] = []
    private var atStart: [[Int]] = []
    private var atStop: [[Int]] = []
    init(scopeCounts: @escaping @Sendable () -> [Int] = { [] }) { self.scopeCounts = scopeCounts }
    var starts: Int { lock.withLock { state.starts } }
    var stops: Int { lock.withLock { state.stops } }
    var active: Int { lock.withLock { state.active } }
    var maxActive: Int { lock.withLock { state.maxActive } }
    /// The next `refusals` starts throw `.streamStartRefused` and count only in `refused`.
    var refusals: Int { get { lock.withLock { state.refusals } } set { lock.withLock { state.refusals = newValue } } }
    var refused: Int { lock.withLock { state.refused } }
    var startURLs: [String] { lock.withLock { started } }
    var scopeAtStart: [[Int]] { lock.withLock { atStart } }
    var scopeAtStop: [[Int]] { lock.withLock { atStop } }

    private struct Stream: FolderEventStream { let onStop: @Sendable () -> Void; func stop() { onStop() } }
    func start(watching url: URL, onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) throws -> any FolderEventStream {
        let key = canonicalPath(url), token = UUID(), scope = scopeCounts()
        try lock.withLock {
            if state.refusals > 0 { state.refusals -= 1; state.refused += 1; throw FolderWatchError.streamStartRefused }
            state.starts += 1; state.active += 1; state.maxActive = max(state.maxActive, state.active)
            started.append(key); atStart.append(scope)
            handlers[key, default: [:]][token] = onHints
        }
        return Stream { [self] in
            let scope = scopeCounts()
            lock.withLock {
                guard handlers[key]?.removeValue(forKey: token) != nil else { return }
                state.stops += 1; state.active -= 1; atStop.append(scope)
            }
        }
    }
    func emit(_ hints: [FolderChangeHint], on url: URL) {
        let targets = lock.withLock { handlers[canonicalPath(url)].map { Array($0.values) } ?? [] }
        for handler in targets { handler(hints) }
    }
}

/// Integer-millisecond clock: `advance(to:)` fires due actions in due order, ties FIFO, `now` = each due time.
final class FakeWatchClock: WatchScheduling, @unchecked Sendable {
    private final class Token: WatchCancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func cancel() { lock.withLock { done = true } }
        var cancelled: Bool { lock.withLock { done } }
    }
    private let lock = NSLock()
    private var now = 0
    private var sequence = 0
    private var pending: [(due: Int, order: Int, token: Token, action: @Sendable () -> Void)] = []
    var nowMilliseconds: Int { lock.withLock { now } }
    func schedule(afterMilliseconds: Int, _ action: @escaping @Sendable () -> Void) -> any WatchCancellable {
        let token = Token()
        lock.withLock { sequence += 1; pending.append((now + afterMilliseconds, sequence, token, action)) }
        return token
    }
    func advance(to time: Int) {
        while let next = lock.withLock({ () -> (@Sendable () -> Void)? in
            pending.removeAll { $0.token.cancelled }
            guard let index = pending.indices.filter({ pending[$0].due <= time })
                .min(by: { (pending[$0].due, pending[$0].order) < (pending[$1].due, pending[$1].order) }) else { return nil }
            let item = pending.remove(at: index)
            now = max(now, item.due)
            return item.action
        }) { next() }
        lock.withLock { now = max(now, time) }
    }
    func advance(by delta: Int) { advance(to: nowMilliseconds + delta) }
}

/// Records the clock time of each `onChange`.
final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int] = []
    private let clock: any WatchScheduling
    init(clock: any WatchScheduling) { self.clock = clock }
    var times: [Int] { lock.withLock { entries } }
    var count: Int { lock.withLock { entries.count } }
    var sink: @Sendable () -> Void {
        { [self] in let at = clock.nowMilliseconds; lock.withLock { entries.append(at) } }
    }
}

/// Positive waits only, bounded like `waitUntil`: throws when the wait ends before the condition holds (#392).
func poll(_ condition: () -> Bool) async throws -> Bool {
    try await waitUntil { condition() }
    return condition()
}

/// Real FileAccess over a fresh temp dir, with the fake source and clock.
struct WatchFixture {
    let base: URL
    let scope = CountingScope()
    let bookmarks = FakeBookmarks()
    let access: FileAccess
    let source: FakeFolderEventSource
    let clock = FakeWatchClock()
    let hub: WatchHub
    init(folders: [String]) throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        for folder in folders { try fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true) }
        access = try FileAccess(scope: scope, bookmarks: bookmarks,
            store: BookmarkStore(url: base.appendingPathComponent("store.json")), buildSHA: "test")
        let scope = scope
        source = FakeFolderEventSource { scope.counts }
        hub = WatchHub(access: access, source: source, scheduler: clock)
    }
    func url(_ path: String) -> URL { base.appendingPathComponent(path) }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension WatchFixture {
    /// Fixture with `root/F/sub`, `root/G`, `root/F2` and an existing `x.png` in each, `root` granted.
    static func filterRoot() async throws -> (WatchFixture, AccessRootID) {
        let f = try WatchFixture(folders: ["root/F/sub", "root/G", "root/F2"])
        for file in ["root/F/x.png", "root/F/sub/x.png", "root/G/x.png", "root/F2/x.png"] {
            FileManager.default.createFile(atPath: f.url(file).path, contents: Data())
        }
        return (f, try await f.access.grant(folder: f.url("root")))
    }
    /// Advances the clock to `t` first (due flushes fire), then emits on the root stream.
    func emit(_ hints: [FolderChangeHint], at t: Int) {
        clock.advance(to: t)
        source.emit(hints, on: url("root"))
    }
    /// Two spellings of one temp path: `/var/...` and `/private/var/...`.
    func spellings(_ path: String) -> (plain: URL, privateVar: URL) {
        let canonical = canonicalPath(url(path.split(separator: "/").prefix(1).joined()))
        let plain = canonical.hasPrefix("/private/") ? String(canonical.dropFirst("/private".count)) : canonical
        let tail = path.split(separator: "/").dropFirst().joined(separator: "/")
        let full = tail.isEmpty ? plain : plain + "/" + tail
        return (URL(fileURLWithPath: full), URL(fileURLWithPath: "/private" + full))
    }
}
