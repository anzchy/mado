import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

// Audit F1: a volume without a UUID (typically an SMB/AFP/NFS/WebDAV share)
// has no remount tracking, but its saved root must keep working.
private struct T229UUIDLessFixture {
    let base: URL
    let root: URL
    let store: BookmarkStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("Share", isDirectory: true)
        store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: root.appendingPathComponent("a.jpg"))
    }
    func save(_ bookmark: Data, id: AccessRootID) throws {
        try store.save([AccessRootRecord(id: id, bookmark: bookmark, displayName: "Share",
            creatingBuildSHA: "old", createdAt: Date(timeIntervalSince1970: 1))])
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
private struct T229UUIDLessNoIdentity: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { nil }
}
private actor T229UUIDLessMounts: DiskMountPort {
    func mountedVolumes() -> [AccessProbeVolume] { [] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}
private let t229UUIDLessVolume = AccessProbeVolume(uuid: nil, url: nil, name: "Share")

private func t229UUIDLessFiles(_ f: T229UUIDLessFixture, scope: CountingScope,
                               codec: FakeBookmarks) throws -> FileAccess {
    try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229",
        resourceReader: T229UUIDLessNoIdentity(), requiresEmbeddedIdentity: true,
        bookmarkVolume: { _ in t229UUIDLessVolume }, resolvedVolumeUUID: { _ in nil },
        bookmarkIdentity: { _ in nil }, mountedVolumesProvider: { [] })
}

@Test(.timeLimit(.minutes(2))) func t229FixUUIDLessRootPublishesAtLaunchAndStaysReadable() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let id = AccessRootID(), scope = CountingScope(), codec = FakeBookmarks()
    try f.save(try codec.create(for: f.root), id: id)
    let files = try t229UUIDLessFiles(f, scope: scope, codec: codec)
    #expect(await files.rootURL(id) == f.root)
    #expect(await files.launchOutcomes()[id] == "resolved")
    let names = try await files.withLease(.root(id, file: f.root)) { lease in
        try FileManager.default.contentsOfDirectory(atPath: lease.url.path)
    }
    #expect(names == ["a.jpg"])
    #expect(scope.counts[0] == scope.counts[1])
}

@Test(.timeLimit(.minutes(2))) func t229FixUUIDLessRootThatFailsItsRealReadIsNotPublished() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let id = AccessRootID(), scope = CountingScope(), codec = FakeBookmarks()
    try f.save(try codec.create(for: f.root), id: id)
    try FileManager.default.removeItem(at: f.root)
    let files = try t229UUIDLessFiles(f, scope: scope, codec: codec)
    #expect(await files.rootURL(id) == nil)
    #expect(await files.launchOutcomes()[id] == "failed")
    #expect(scope.counts[0] == scope.counts[1])
}

@Test(.timeLimit(.minutes(2))) func t229FixUUIDLessStaleRefreshKeepsRootReadable() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let scope = CountingScope(), codec = FakeBookmarks()
    let files = try t229UUIDLessFiles(f, scope: scope, codec: codec)
    let id = try await files.grant(folder: f.root)
    #expect(codec.count == 1)
    codec.stale = true
    #expect(try await files.probeRootURL(id) == f.root)
    #expect(await files.rootURL(id) == f.root)
    #expect(codec.count == 2)
    #expect(scope.counts[0] == scope.counts[1])
}

@Test(.timeLimit(.minutes(2))) func t229FixUUIDLessForegroundRetryRecoversReadableRoot() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let id = AccessRootID(), scope = CountingScope(), codec = FakeBookmarks()
    try f.save(try codec.create(for: f.root), id: id)
    let moved = f.base.appendingPathComponent("away", isDirectory: true)
    try FileManager.default.moveItem(at: f.root, to: moved)
    let files = try t229UUIDLessFiles(f, scope: scope, codec: codec)
    #expect(await files.rootURL(id) == nil)
    let offline = await files.verifySavedRootForRecovery(id, mounts: T229UUIDLessMounts())
    #expect(offline.classification.cause != .readable)
    #expect(offline.rootURL == nil)
    try FileManager.default.moveItem(at: moved, to: f.root)
    let result = await files.verifySavedRootForRecovery(id, mounts: T229UUIDLessMounts())
    #expect(result.classification.cause == .readable)
    #expect(result.rootURL == f.root)
    #expect(result.bookmarkVolume.uuid == nil)
    #expect(await files.rootURL(id) == f.root)
    #expect(scope.counts[0] == scope.counts[1])
}

private final class T229UUIDLessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var uuid: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Test(.timeLimit(.minutes(2))) func t229FixUUIDLessStaleRefreshRefusesRootThatNowReportsAUUID() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let scope = CountingScope(), codec = FakeBookmarks(), resolved = T229UUIDLessBox()
    let files = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229",
        resourceReader: T229UUIDLessNoIdentity(), requiresEmbeddedIdentity: true,
        bookmarkVolume: { _ in t229UUIDLessVolume }, resolvedVolumeUUID: { _ in resolved.uuid },
        bookmarkIdentity: { _ in nil }, mountedVolumesProvider: { [] })
    let id = try await files.grant(folder: f.root)
    let before = try Data(contentsOf: f.store.url)
    codec.stale = true
    resolved.uuid = "other-volume"
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await files.probeRootURL(id) }
    #expect(await files.rootURL(id) == nil)
    #expect(codec.count == 1)
    #expect(try Data(contentsOf: f.store.url) == before)
    #expect(scope.counts[0] == scope.counts[1])
}

private final class T229MissingFolderReader: FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var missing: String?
    func vanish(_ folder: URL) { lock.withLock { missing = folder.standardizedFileURL.resolvingSymlinksInPath().path } }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        if lock.withLock({ missing }) == fileURL.standardizedFileURL.resolvingSymlinksInPath().path {
            throw POSIXError(.ENOENT)
        }
        return try URLIdentityResourceReader().identity(for: fileURL)
    }
}

// A missing folder reported in the POSIX domain still means "fall back", not "lost".
@Test(.timeLimit(.minutes(2))) func t229FixRecoveryFolderPOSIXMissingErrorFallsBackToRoot() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let child = f.root.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let reader = T229MissingFolderReader(), scope = CountingScope()
    let files = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: f.store, buildSHA: "T229",
        resourceReader: reader)
    let id = try await files.grant(folder: f.root)
    let reference = try #require(try await files.captureRecoveryFolder(rootID: id, folder: child))
    reader.vanish(child)
    #expect(try await files.resolveRecoveryFolder(reference, verifiedRoot: f.root) == nil)
    #expect(scope.counts[0] == scope.counts[1])
}

@Test(.timeLimit(.minutes(2))) func t229FixUUIDLessStaleRefreshRefusesRootWithOtherKnownIdentity() async throws {
    let f = try T229UUIDLessFixture(); defer { f.remove() }
    let scope = CountingScope(), codec = FakeBookmarks()
    let saved = FileResourceIdentity(volumeUUID: "saved", fileIdentifier: "root")
    let files = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229",
        resourceReader: T229UUIDLessNoIdentity(), requiresEmbeddedIdentity: true,
        bookmarkVolume: { _ in t229UUIDLessVolume }, resolvedVolumeUUID: { _ in nil },
        bookmarkIdentity: { _ in saved }, mountedVolumesProvider: { [] })
    let id = try await files.grant(folder: f.root)
    codec.stale = true
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await files.probeRootURL(id) }
    #expect(await files.rootURL(id) == nil)
    #expect(codec.count == 1)
    #expect(scope.counts[0] == scope.counts[1])
}
