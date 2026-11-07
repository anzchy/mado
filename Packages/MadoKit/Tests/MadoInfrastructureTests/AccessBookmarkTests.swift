import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

final class FakeBookmarks: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    var relocated: URL?
    var stale = false
    var fails = false
    var creationFails = false
    private var creations = 0
    var count: Int { lock.withLock { creations } }
    func create(for url: URL) throws -> Data {
        try lock.withLock {
            if creationFails { throw FileAccessError.invalidFolder }
            creations += 1
            return Data(url.path.utf8)
        }
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        try lock.withLock {
            if fails { throw FileAccessError.corruptStore }
            return ResolvedBookmark(url: relocated ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: stale)
        }
    }
}

@Test func accessBookmarksSurviveRelaunchRefreshStaleAndReportFailures() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let folder = base.appendingPathComponent("photos")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("a.jpg")
    let store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
    let codec = FakeBookmarks(); let scope = CountingScope()
    let first = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "A")
    let id = try await first.grant(folder: folder)
    #expect(try store.load().count == 1)
    let saved = try #require(store.load().first)
    #expect(saved.id == id && saved.displayName == "photos" && saved.creatingBuildSHA == "A")
    #expect(saved.createdAt.timeIntervalSinceNow <= 0)
    #expect(await first.rootCovering(file) == id)
    #expect(await first.rootCovering(base) == nil)
    let second = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "B")
    #expect(await second.launchOutcomes()[id] == "resolved")
    let lease = try await second.acquire(.root(id, file: file))
    await second.release(lease)
    codec.stale = true
    let stale = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "C")
    #expect(await stale.launchOutcomes()[id] == "stale")
    #expect(codec.count == 2)
    #expect(try store.load().first?.creatingBuildSHA == "A")
    #expect(await stale.records().count == 1)
    codec.fails = true
    let failed = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "D")
    #expect(await failed.launchOutcomes()[id] == "failed")
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await failed.acquire(.root(id, file: file)) }
    #expect(await failed.rootCovering(file) == nil)
    #expect(try store.load().count == 1)
    codec.fails = false; codec.creationFails = true
    let cannotRefresh = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "E")
    #expect(await cannotRefresh.launchOutcomes()[id] == "failed")
    #expect(scope.counts[0] == scope.counts[1])
}

@Test func accessFileGrantNeverPersistsAndCorruptStoreIsReported() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let scope = CountingScope(); let codec = FakeBookmarks()
    let first = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "A")
    let file = base.appendingPathComponent("one.jpg")
    let lease = try await first.acquire(.fileGrant(file)); await first.release(lease)
    let second = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "B")
    #expect(await second.rootCovering(file) == nil)
    #expect(try store.load().isEmpty)
    #expect(codec.count == 0) // The synthetic missing file cannot yield a session bookmark.
    try Data("broken JSON".utf8).write(to: store.url)
    let recovered = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "C")
    #expect(await recovered.storeCorrupt)
    #expect(await recovered.records().isEmpty)
    let fileLease = try await recovered.acquire(.fileGrant(file))
    await recovered.release(fileLease)
    let id = try await recovered.grant(folder: base)
    let rootLease = try await recovered.acquire(.root(id, file: file))
    await recovered.release(rootLease)
    #expect(try Data(contentsOf: store.url) == Data("broken JSON".utf8))
    let relaunched = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "D")
    #expect(await relaunched.storeCorrupt)
    #expect(await relaunched.rootCovering(file) == id)
    #expect(scope.counts[0] == scope.counts[1])
}

@Test func accessAcquireRefreshesNewlyStaleBookmarkAndRejectsLostRoot() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let scope = CountingScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "A")
    let id = try await access.grant(folder: base)
    codec.stale = true
    let lease = try await access.acquire(.root(id, file: base.appendingPathComponent("a.jpg")))
    #expect(codec.count == 2)
    let second = try await access.acquire(.root(id, file: base.appendingPathComponent("b.jpg")))
    #expect(codec.count == 2)
    await access.release(lease); await access.release(second)
    codec.creationFails = true
    await #expect(throws: FileAccessError.needsReconnection(id)) {
        try await access.acquire(.root(id, file: base))
    }
    #expect(await access.rootCovering(base) == nil)
    #expect(scope.counts[0] == scope.counts[1])
    let restored = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: store, buildSHA: "B")
    codec.fails = true
    let otherID = try await restored.grant(folder: base)
    #expect(otherID == id)
    let different = base.appendingPathComponent("different", isDirectory: true)
    try fm.createDirectory(at: different, withIntermediateDirectories: true)
    let differentID = try await restored.grant(folder: different)
    #expect(differentID != id)
}

@Test func accessRejectsNonFolderAndLaterBookmarkResolutionFailure() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let file = base.appendingPathComponent("file.jpg")
    try Data().write(to: file)
    let scope = CountingScope(); let codec = FakeBookmarks()
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let access = try FileAccess(scope: scope, bookmarks: codec, store: store, buildSHA: "A")
    await #expect(throws: FileAccessError.invalidFolder) { try await access.grant(folder: file) }
    let id = try await access.grant(folder: base)
    codec.fails = true
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.acquire(.root(id, file: file)) }
    #expect(await access.rootCovering(file) == nil)
    #expect(scope.counts[0] == scope.counts[1])
}

@Test func accessRelocatedRootSharesResolvedScopeAcrossConcurrentLeases() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let original = base.appendingPathComponent("original")
    let moved = base.appendingPathComponent("moved")
    try fm.createDirectory(at: original, withIntermediateDirectories: true)
    let codec = FakeBookmarks(); let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: codec,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "A")
    let id = try await access.grant(folder: original)
    try fm.moveItem(at: original, to: moved)
    codec.relocated = moved
    let first = try await access.acquire(.root(id, file: moved.appendingPathComponent("a.jpg")))
    // The first window is still holding its lease when the second window arrives.
    let second = try await access.acquire(.root(id, file: moved.appendingPathComponent("b.jpg")))
    #expect(first.url == moved && second.url == moved)
    #expect(scope.counts == [2, 1])
    #expect(await access.rootCovering(moved.appendingPathComponent("c.jpg")) == id)
    #expect(await access.rootCovering(original.appendingPathComponent("c.jpg")) == nil)
    await access.release(first)
    #expect(scope.counts == [2, 1])
    await access.release(second)
    #expect(scope.counts == [2, 2])
}

@Test func accessIncompatiblePrimaryAndCorruptRecoveryStillAllowFileGrants() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let incompatible = Data("{\"version\":999}".utf8)
    let corruptRecovery = Data("broken recovery".utf8)
    try incompatible.write(to: store.url)
    try corruptRecovery.write(to: store.url.appendingPathExtension("recovered"))
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: store, buildSHA: "A")
    #expect(await access.storeCorrupt)
    #expect(await access.records().isEmpty)
    let lease = try await access.acquire(.fileGrant(base.appendingPathComponent("a.jpg")))
    await access.release(lease)
    #expect(scope.counts == [1, 1])
    #expect(try Data(contentsOf: store.url) == incompatible)
    #expect(try Data(contentsOf: store.url.appendingPathExtension("recovered")) == corruptRecovery)
}
