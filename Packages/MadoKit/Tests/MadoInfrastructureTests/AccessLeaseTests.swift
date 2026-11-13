import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

final class CountingScope: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    var succeeds = true
    func isReadable(_ url: URL) -> Bool { false }
    func start(_ url: URL) -> Bool { lock.withLock { starts += 1; return succeeds } }
    func stop(_ url: URL) { lock.withLock { stops += 1 } }
    var counts: [Int] { lock.withLock { [starts, stops] } }
}

@Test(.timeLimit(.minutes(2))) func accessLeasesBalanceAcrossWindowsFailuresAndCancellation() async throws {
    let scope = CountingScope()
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: storeURL), buildSHA: "test")
    let folder = URL(fileURLWithPath: "/tmp")
    let root = try await access.grant(folder: folder)
    let request = AccessRequest.root(root, file: folder.appendingPathComponent("a.jpg"))
    let first = try await access.acquire(request)
    let second = try await access.acquire(request)
    #expect(scope.counts == [2, 1])
    await access.release(first); await access.release(first)
    #expect(scope.counts == [2, 1])
    await access.release(second)
    #expect(scope.counts == [2, 2])
    await #expect(throws: FileAccessError.outsideRoot) {
        try await access.acquire(.root(root, file: URL(fileURLWithPath: "/elsewhere/a.jpg")))
    }
    let unknown = AccessRootID()
    await #expect(throws: FileAccessError.needsReconnection(unknown)) {
        try await access.acquire(.root(unknown, file: folder))
    }
}

@Test(.timeLimit(.minutes(2))) func accessFileGrantFailedStartNeverStopsAndScopesOnlyOneFile() async throws {
    let scope = CountingScope(); scope.succeeds = false
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: storeURL), buildSHA: "test")
    let file = URL(fileURLWithPath: "/tmp/a.jpg")
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.fileGrant(file)) }
    #expect(scope.counts == [1, 0])
    scope.succeeds = true
    let root = try await access.grant(folder: file.deletingLastPathComponent())
    scope.succeeds = false
    await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.root(root, file: file)) }
    #expect(scope.counts == [3, 1])
    scope.succeeds = true
    let lease = try await access.acquire(.fileGrant(file))
    #expect(lease.rootID == nil)
    #expect(lease.url == file)
    await access.release(lease)
    enum Failure: Error { case expected }
    await #expect(throws: Failure.expected) {
        try await access.withLease(.fileGrant(file)) { _ in throw Failure.expected }
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await access.withLease(.fileGrant(file)) { _ in 1 }
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let value = try await access.withLease(.fileGrant(file)) { _ in 42 }
    #expect(value == 42)
    #expect(scope.counts == [7, 5])
}

private final class LinkChangingScope: SecurityScope, @unchecked Sendable {
    let link: URL
    let outside: URL
    private let lock = NSLock()
    private var armed = false
    private var starts = 0
    private var stops = 0
    init(link: URL, outside: URL) { self.link = link; self.outside = outside }
    func arm() { lock.withLock { armed = true } }
    func isReadable(_ url: URL) -> Bool { false }
    func start(_ url: URL) -> Bool {
        lock.withLock {
            starts += 1
            if armed {
                try! FileManager.default.removeItem(at: link)
                try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                armed = false
            }
            return true
        }
    }
    func stop(_ url: URL) { lock.withLock { stops += 1 } }
    var balanced: Bool { lock.withLock { starts == stops } }
}

@Test(.timeLimit(.minutes(2))) func accessBoundaryIsRecheckedAfterScopeActuallyStarts() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("root")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let inside = root.appendingPathComponent("inside.jpg")
    let outside = base.appendingPathComponent("outside.jpg")
    let link = root.appendingPathComponent("link.jpg")
    try Data().write(to: inside); try Data().write(to: outside)
    try fm.createSymbolicLink(at: link, withDestinationURL: inside)
    let scope = LinkChangingScope(link: link, outside: outside)
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "A")
    let id = try await access.grant(folder: root)
    scope.arm()
    await #expect(throws: FileAccessError.outsideRoot) {
        let lease = try await access.acquire(.root(id, file: link))
        await access.release(lease)
    }
    #expect(scope.balanced)
}

private final class ScopeSensitiveBoundary: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var checks = 0
    private var unscoped = 0
    var allowsStart = true
    func isReadable(_ url: URL) -> Bool { false }
    func start(_ url: URL) -> Bool {
        lock.withLock { if allowsStart { live += 1 }; return allowsStart }
    }
    func stop(_ url: URL) { lock.withLock { live -= 1 } }
    func contains(_ file: URL, _ root: URL) -> Bool {
        lock.withLock {
            checks += 1
            if live == 0 { unscoped += 1; return false }
            return AccessBoundary.contains(file, in: root)
        }
    }
    var observations: [Int] { lock.withLock { [live, checks, unscoped] } }
}

@Test(.timeLimit(.minutes(2))) func accessDiscoversRootsOnlyAfterScopedBoundaryConfirmation() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let scope = ScopeSensitiveBoundary()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "A",
        boundary: { scope.contains($0, $1) })
    let id = try await access.grant(folder: base)
    #expect(await access.rootCovering(base.appendingPathComponent("a.jpg")) == id)
    #expect(await access.rootCovering(base.deletingLastPathComponent()) == nil)
    #expect(scope.observations == [0, 2, 0])
    scope.allowsStart = false
    #expect(await access.rootCovering(base.appendingPathComponent("a.jpg")) == nil)
    #expect(scope.observations == [0, 2, 0])
}

@Test(.timeLimit(.minutes(2))) func accessFailedPanelGrantLeavesStoreUntouchedAndNeverStopsFailedScope() async throws {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeURL) }
    let scope = CountingScope(); scope.succeeds = false
    let store = BookmarkStore(url: storeURL)
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: store, buildSHA: "A")
    await #expect(throws: FileAccessError.startFailed) {
        try await access.grant(folder: URL(fileURLWithPath: "/tmp"))
    }
    #expect(scope.counts == [1, 0])
    #expect(await access.records().isEmpty)
    #expect(try store.load().isEmpty)
}
