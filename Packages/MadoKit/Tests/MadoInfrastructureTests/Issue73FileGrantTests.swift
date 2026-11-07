import Foundation
import Testing
import MadoCore
import MadoInfrastructure

/// Only the operating-system scope/readability boundary is simulated.
final class Issue73Scope: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    // Bookmark resolution can add a directory slash; scope accounting follows filesystem paths.
    private var rules: [String: (start: Bool, readable: Bool)] = [:]
    private var attempts: [String: Int] = [:]
    private var stops: [String: Int] = [:]
    func configure(_ url: URL, start: Bool, readable: Bool) {
        lock.withLock { rules[url.path] = (start, readable) }
    }
    func start(_ url: URL) -> Bool {
        lock.withLock { attempts[url.path, default: 0] += 1; return rules[url.path]?.start ?? false }
    }
    func isReadable(_ url: URL) -> Bool { lock.withLock { rules[url.path]?.readable ?? false } }
    func stop(_ url: URL) { lock.withLock { stops[url.path, default: 0] += 1 } }
    func counts(_ url: URL) -> [Int] { lock.withLock { [attempts[url.path, default: 0], stops[url.path, default: 0]] } }
}

@Test func issue73ReadableFileGrantSharesAndRetiresTokensWithoutStopping() async throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let scope = Issue73Scope(), file = URL(fileURLWithPath: "/tmp/drop-A.png")
    scope.configure(file, start: false, readable: true)
    let store = BookmarkStore(url: storeURL)
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: store, buildSHA: "issue73")
    let first = try await access.acquire(.fileGrant(file))
    let second = try await access.acquire(.fileGrant(file))
    #expect(first.token != second.token)
    #expect(first.url == file && second.url == file)
    #expect(first.rootID == nil && second.rootID == nil)
    scope.configure(file, start: false, readable: false)
    await access.release(first); await access.release(first)
    let third = try await access.acquire(.fileGrant(file))
    #expect(third.url == file && third.token != second.token)
    await access.release(second); await access.release(third)
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    scope.configure(file, start: false, readable: true)
    let fresh = try await access.acquire(.fileGrant(file))
    scope.configure(file, start: false, readable: false)
    await access.release(first); await access.release(second); await access.release(third)
    let sharedFresh = try await access.acquire(.fileGrant(file))
    #expect(sharedFresh.token != fresh.token && sharedFresh.url == file)
    await access.release(fresh); await access.release(sharedFresh)
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    #expect(scope.counts(file) == [4, 0])
    #expect(await access.records().isEmpty)
    #expect(try store.load().isEmpty)
}

@Test func issue73UnreadableFileGrantCanRetryWithoutPersistingAuthority() async throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let scope = Issue73Scope(), file = URL(fileURLWithPath: "/tmp/denied.png")
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: storeURL), buildSHA: "issue73")
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    scope.configure(file, start: false, readable: true)
    let lease = try await access.acquire(.fileGrant(file))
    #expect(lease.url == file && lease.rootID == nil)
    await access.release(lease)
    #expect(scope.counts(file) == [2, 0])
    #expect(await access.records().isEmpty)
}

@Test func issue73ReadableRootsPanelAndStaleRefreshStillRequireScopeStart() async throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let file = tree.appendingPathComponent("image.png"), scope = Issue73Scope(), codec = FakeBookmarks()
    let store = BookmarkStore(url: tree.appendingPathComponent("roots.json"))
    scope.configure(tree, start: true, readable: true)
    let access = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "issue73")
    let id = try await access.grant(folder: tree)
    scope.configure(tree, start: false, readable: true)
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.root(id, file: file)) }
    await #expect(throws: FileAccessError.startFailed) { try await access.grant(folder: tree) }
    #expect(await access.rootCovering(file) == nil)
    #expect(try store.load().map(\.id) == [id])
    codec.stale = true
    let relaunched = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "issue73-relaunch")
    #expect(await relaunched.launchOutcomes()[id] == "failed")
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await relaunched.acquire(.root(id, file: file)) }
    #expect(codec.count == 1)
    #expect(scope.counts(tree) == [5, 1])
}

@Test func issue73StartedFileGrantSharesAndStopsOnlyAfterFinalRelease() async throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let scope = Issue73Scope(), file = URL(fileURLWithPath: "/tmp/started.png")
    scope.configure(file, start: true, readable: false)
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: storeURL), buildSHA: "issue73")
    let first = try await access.acquire(.fileGrant(file)), second = try await access.acquire(.fileGrant(file))
    #expect(first.url == file && second.url == file && first.token != second.token)
    await access.release(second)
    #expect(scope.counts(file) == [1, 0])
    await access.release(first); await access.release(second)
    #expect(scope.counts(file) == [1, 1])
    #expect(await access.records().isEmpty)
}

@Test func issue73FallbackReleasesAfterBodyFailureAndCancellation() async throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let scope = Issue73Scope(), file = URL(fileURLWithPath: "/tmp/cancelled.png")
    scope.configure(file, start: false, readable: true)
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: storeURL), buildSHA: "issue73")
    enum Failure: Error { case body }
    await #expect(throws: Failure.body) {
        try await access.withLease(.fileGrant(file)) { _ in throw Failure.body }
    }
    scope.configure(file, start: false, readable: false)
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    scope.configure(file, start: false, readable: true)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await access.withLease(.fileGrant(file)) { _ in 1 }
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    scope.configure(file, start: false, readable: false)
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    scope.configure(file, start: false, readable: true)
    let value = try await access.withLease(.fileGrant(file)) { lease in lease.url.lastPathComponent }
    #expect(value == "cancelled.png")
    scope.configure(file, start: false, readable: false)
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    #expect(scope.counts(file) == [6, 0])
    #expect(await access.records().isEmpty)
}

@Test(arguments: [true, false]) func issue73DistinctFileLeasesKeepIndependentScopeOwnership(releaseFallbackFirst: Bool) async throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let scope = Issue73Scope(), a = URL(fileURLWithPath: "/tmp/mixed-A.png"), b = URL(fileURLWithPath: "/tmp/mixed-B.png")
    scope.configure(a, start: false, readable: true)
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: storeURL), buildSHA: "issue73")
    let a1 = try await access.acquire(.fileGrant(a)), a2 = try await access.acquire(.fileGrant(a))
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(b)) }
    scope.configure(b, start: true, readable: false)
    let b1 = try await access.acquire(.fileGrant(b))
    #expect(a1.url == a && a2.url == a && b1.url == b)
    #expect(a1.rootID == nil && b1.rootID == nil)
    scope.configure(a, start: false, readable: false); scope.configure(b, start: false, readable: false)
    if releaseFallbackFirst {
        await access.release(a1); await access.release(a2); await access.release(a1)
        await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(a)) }
        let b2 = try await access.acquire(.fileGrant(b))
        #expect(b2.url == b && b2.token != b1.token)
        await access.release(b1); await access.release(b2)
        await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(b)) }
    } else {
        await access.release(b1); await access.release(b1)
        await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(b)) }
        let a3 = try await access.acquire(.fileGrant(a))
        #expect(a3.url == a && a3.token != a1.token)
        await access.release(a1); await access.release(a3); await access.release(a2)
        await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(a)) }
    }
    #expect(scope.counts(a) == [2, 0])
    #expect(scope.counts(b) == [3, 1])
    #expect(await access.records().isEmpty)
}
