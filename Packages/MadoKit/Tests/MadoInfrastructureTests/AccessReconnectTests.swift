import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

enum ReconnectTestError: Error { case bookmark }

final class ReconnectScope: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL: Int] = [:]
    private var stopped: [URL: Int] = [:]
    private var denied: [URL: Int] = [:]
    private var stopOrder: [URL] = []
    var rejected: URL?
    var beforeStart: (@Sendable (URL) -> Void)?
    func start(_ url: URL) -> Bool {
        beforeStart?(url)
        return lock.withLock {
            if url == rejected { denied[url, default: 0] += 1; return false }
            started[url, default: 0] += 1
            return true
        }
    }
    func stop(_ url: URL) {
        lock.withLock { stopped[url, default: 0] += 1; stopOrder.append(url) }
    }
    func isReadable(_ url: URL) -> Bool { false }
    func counts(_ url: URL) -> [Int] {
        lock.withLock { [started[url, default: 0], stopped[url, default: 0], denied[url, default: 0]] }
    }
    var balanced: Bool { lock.withLock { started == stopped } }
    var liveCount: Int { lock.withLock { started.values.reduce(0, +) - stopped.values.reduce(0, +) } }
    var stops: [URL] { lock.withLock { stopOrder } }
}

final class ReconnectBookmarks: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    var failingBookmarks: Set<Data> = []
    var creationFails = false
    var onCreate: (@Sendable () -> Void)?
    var count: Int { lock.withLock { creations } }
    func create(for url: URL) throws -> Data {
        onCreate?()
        return try lock.withLock {
            if creationFails { throw ReconnectTestError.bookmark }
            creations += 1
            return Data("\(creations)|\(url.standardizedFileURL.resolvingSymlinksInPath().path)".utf8)
        }
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        try lock.withLock {
            if failingBookmarks.contains(data) { throw FileAccessError.corruptStore }
            let path = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).last!
            return ResolvedBookmark(url: URL(fileURLWithPath: String(path)), stale: false)
        }
    }
}

struct ReconnectFixture {
    let base: URL
    let old: URL
    let chosen: URL
    let store: BookmarkStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        old = base.appendingPathComponent("old", isDirectory: true)
        chosen = base.appendingPathComponent("new", isDirectory: true)
        store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
        for folder in [old, chosen] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("image".utf8).write(to: folder.appendingPathComponent("a.png"))
        }
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Test(.timeLimit(.minutes(2))) func p201ReconnectFailedRootKeepsIdentityAndSurvivesRelaunch() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = ReconnectBookmarks(); let scope = ReconnectScope()
    let first = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await first.grant(folder: f.old)
    let original = try #require(f.store.load().first)
    codec.failingBookmarks = [original.bookmark]
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.acquire(.root(id, file: f.old)) }
    codec.failingBookmarks = []
    #expect(try await access.reconnect(id, folder: f.chosen) == f.chosen)
    let saved = try #require(f.store.load().first)
    #expect(try f.store.load().count == 1)
    #expect(saved.id == id)
    #expect(saved.bookmark != original.bookmark)
    #expect(saved.displayName == "new")
    #expect(saved.creatingBuildSHA == "A")
    #expect(saved.createdAt == original.createdAt)
    let lease = try await access.acquire(.root(id, file: f.chosen.appendingPathComponent("a.png")))
    #expect(lease.url == f.chosen && lease.rootID == id)
    await access.release(lease)
    #expect(await access.rootCovering(f.chosen.appendingPathComponent("a.png")) == id)
    await #expect(throws: FileAccessError.outsideRoot) { try await access.acquire(.root(id, file: f.old)) }
    let relaunched = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "C")
    let next = try await relaunched.acquire(.root(id, file: f.chosen.appendingPathComponent("a.png")))
    #expect(next.url == f.chosen && next.rootID == id)
    await relaunched.release(next)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2))) func p201ReconnectMissingRecordUsesSuppliedID() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks(); let id = AccessRootID()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "current")
    #expect(try await access.reconnect(id, folder: f.chosen) == f.chosen)
    let saved = try #require(f.store.load().first)
    #expect(saved.id == id && saved.displayName == "new" && saved.creatingBuildSHA == "current")
    #expect(try f.store.load().count == 1)
    #expect(await access.rootCovering(f.chosen.appendingPathComponent("a.png")) == id)
    let relaunched = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "next")
    let lease = try await relaunched.acquire(.root(id, file: f.chosen))
    #expect(lease.rootID == id && lease.url == f.chosen)
    await relaunched.release(lease)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true], ["start", "directory", "bookmark", "save"])
func p201ReconnectFailuresPreserveLiveAndFailedState(failed: Bool, kind: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let first = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await first.grant(folder: f.old)
    let original = try #require(f.store.load().first)
    if failed { codec.failingBookmarks = [original.bookmark] }
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    codec.failingBookmarks = []
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    let selection = kind == "directory" ? f.chosen.appendingPathComponent("a.png") : f.chosen
    let before = scope.counts(selection)
    if kind == "start" { scope.rejected = selection }
    if kind == "bookmark" { codec.creationFails = true }
    let support = f.store.url.deletingLastPathComponent()
    if kind == "save" { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path) }
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path) }
    switch kind {
    case "start":
        await #expect(throws: FileAccessError.startFailed) { try await access.reconnect(id, folder: selection) }
    case "directory":
        await #expect(throws: FileAccessError.invalidFolder) { try await access.reconnect(id, folder: selection) }
    case "bookmark":
        await #expect(throws: ReconnectTestError.bookmark) { try await access.reconnect(id, folder: selection) }
    default:
        await #expect(throws: CocoaError.self) { try await access.reconnect(id, folder: selection) }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(await access.records() == records)
    if kind == "start" { #expect(scope.counts(selection) == [before[0], before[1], before[2] + 1]) }
    else { #expect(scope.counts(selection) == [before[0] + 1, before[1] + 1, before[2]]) }
    scope.rejected = nil; codec.creationFails = false
    if failed {
        await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.acquire(.root(id, file: f.old)) }
    } else {
        let lease = try await access.acquire(.root(id, file: f.old))
        #expect(lease.url == f.old)
        await access.release(lease)
    }
    #expect(scope.balanced)
}

private final class ReconnectPhaseWitness: @unchecked Sendable {
    let lock = NSLock()
    var startsSawOriginal = true
    var createsScoped = true
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func p201ReconnectScopePrecedesDirectoryBookmarkAndPersistence(denied: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let bytes = try Data(contentsOf: f.store.url); let creations = codec.count
    let createdByStart = f.base.appendingPathComponent("created-by-start", isDirectory: true)
    let selection = denied ? f.chosen : createdByStart
    let witness = ReconnectPhaseWitness()
    scope.rejected = denied ? selection : nil
    scope.beforeStart = { url in
        guard url == selection else { return }
        witness.lock.withLock {
            witness.startsSawOriginal = (try? Data(contentsOf: f.store.url)) == bytes && codec.count == creations
        }
        if !denied { try? FileManager.default.createDirectory(at: createdByStart, withIntermediateDirectories: true) }
    }
    codec.onCreate = { witness.lock.withLock { witness.createsScoped = scope.liveCount > 0 } }
    if denied {
        await #expect(throws: FileAccessError.startFailed) { try await access.reconnect(id, folder: selection) }
        #expect(try Data(contentsOf: f.store.url) == bytes)
        #expect(codec.count == creations)
        #expect(scope.counts(selection) == [0, 0, 1])
    } else {
        #expect(try await access.reconnect(id, folder: selection) == selection)
        #expect(try f.store.load().first?.displayName == "created-by-start")
        #expect(codec.count == creations + 1)
        #expect(scope.counts(selection) == [1, 1, 0])
    }
    #expect(witness.lock.withLock { witness.startsSawOriginal && witness.createsScoped })
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: ["direct", "slash", "alias", "nested", "prefix"])
func p201ReconnectRejectsOnlyExactOtherRoot(kind: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let other = try await access.grant(folder: f.chosen)
    let alias = f.base.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.chosen)
    let nested = f.chosen.appendingPathComponent("nested", isDirectory: true)
    let prefix = f.base.appendingPathComponent("new-extra", isDirectory: true)
    for folder in [nested, prefix] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let selected: URL
    switch kind {
    case "slash": selected = URL(fileURLWithPath: f.chosen.path + "/", isDirectory: true)
    case "alias": selected = alias
    case "nested": selected = nested
    case "prefix": selected = prefix
    default: selected = f.chosen
    }
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    if kind == "nested" || kind == "prefix" {
        #expect(try await access.reconnect(id, folder: selected) == selected)
        #expect(try f.store.load().count == 2)
    } else {
        await #expect(throws: FileAccessError.alreadyGranted(other)) { try await access.reconnect(id, folder: selected) }
        #expect(try Data(contentsOf: f.store.url) == bytes)
        #expect(await access.records() == records)
        let firstLease = try await access.acquire(.root(id, file: f.old))
        #expect(firstLease.url == f.old)
        await access.release(firstLease)
    }
    let otherLease = try await access.acquire(.root(other, file: f.chosen))
    #expect(otherLease.url == f.chosen)
    await access.release(otherLease)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func p201ReconnectMatchesPostScopeSymlinkIdentity(collision: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let other = try await access.grant(folder: f.chosen)
    let distinct = f.base.appendingPathComponent("distinct", isDirectory: true)
    try FileManager.default.createDirectory(at: distinct, withIntermediateDirectories: true)
    let alias = f.base.appendingPathComponent("selection", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: collision ? distinct : f.chosen)
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records(); let count = codec.count
    scope.beforeStart = { url in
        guard url == alias else { return }
        try? FileManager.default.removeItem(at: alias)
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: collision ? f.chosen : distinct)
    }
    if collision {
        await #expect(throws: FileAccessError.alreadyGranted(other)) { try await access.reconnect(id, folder: alias) }
        #expect(try Data(contentsOf: f.store.url) == bytes)
        #expect(await access.records() == records)
        #expect(codec.count == count)
    } else {
        let result = try await access.reconnect(id, folder: alias)
        #expect(result.resolvingSymlinksInPath() == distinct)
        let saved = try #require(f.store.load().first { $0.id == id })
        #expect(try codec.resolve(saved.bookmark).url == distinct)
        #expect(try f.store.load().first { $0.id == other } == records.first { $0.id == other })
        let lease = try await access.acquire(.root(id, file: distinct))
        #expect(lease.url == distinct)
        await access.release(lease)
    }
    #expect(scope.balanced)
}
