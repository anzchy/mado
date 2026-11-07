import Foundation
import AppKit
import Testing
import MadoCore
@testable import MadoInfrastructure

private actor T229Mounts: DiskMountPort {
    var volumes: [AccessProbeVolume]
    private var continuation: AsyncStream<DiskMountEvent>.Continuation?
    init(_ volumes: [AccessProbeVolume]) { self.volumes = volumes }
    func mountedVolumes() -> [AccessProbeVolume] { volumes }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { continuation = $0 } }
    func set(_ volumes: [AccessProbeVolume]) { self.volumes = volumes }
    func emit(_ event: DiskMountEvent) { continuation?.yield(event) }
}

private struct T229IdentityReader: FileIdentityResourceReading {
    let identity: FileResourceIdentity?
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { identity }
}

private final class T229BookmarkCodec: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private var movedTo: URL?
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func setRelocated(_ url: URL) { lock.withLock { movedTo = url } }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        try lock.withLock {
            if failing { throw CocoaError(.fileReadNoSuchFile) }
            if let movedTo { return ResolvedBookmark(url: movedTo, stale: false) }
            return ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true), stale: false)
        }
    }
}

private final class T229Scope: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var allowed = true
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    func setAllowed(_ value: Bool) { lock.withLock { allowed = value } }
    func start(_ url: URL) -> Bool {
        lock.withLock {
            starts += 1
            return allowed
        }
    }
    func stop(_ url: URL) { lock.withLock { stops += 1 } }
    func isReadable(_ url: URL) -> Bool { true }
}

private struct T229Fixture {
    let base: URL
    let root: URL
    let child: URL
    let store: BookmarkStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("Photos", isDirectory: true)
        child = root.appendingPathComponent("child", isDirectory: true)
        store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

private final class T229MountedSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AccessProbeVolume]
    init(_ volumes: [AccessProbeVolume]) { stored = volumes }
    func get() -> [AccessProbeVolume] { lock.withLock { stored } }
    func set(_ volumes: [AccessProbeVolume]) { lock.withLock { stored = volumes } }
}

private func nextEvent(in stream: AsyncStream<DiskMountEvent>) async -> DiskMountEvent? {
    // Let the enclosing test's time limit detect missing events. A separate
    // timer can win while the native test suite delays MainActor delivery.
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}

private func volume(_ uuid: String?, name: String = "Photos") -> AccessProbeVolume {
    AccessProbeVolume(uuid: uuid, url: URL(fileURLWithPath: "/Volumes/Photos"), name: name)
}

@Test func t229VerifyRejectsSameNameWrongUUIDBeforeTrustingOldMountPoint() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let scope = T229Scope(), codec = T229BookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" })
    let id = try await access.grant(folder: fixture.root)
    let starts = scope.counts.0
    let impostor = T229Mounts([volume("333")])
    let result = await access.verifySavedRootForRecovery(id, folder: fixture.root, mounts: impostor)
    #expect(result.classification.cause == .diskNotConnected)
    #expect(result.rootURL == nil && result.folderURL == nil)
    #expect(result.bookmarkVolume.name == "Photos")
    #expect(scope.counts.0 == starts)
    #expect(await access.records().first?.id == id)
    let unknown = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume(nil) }, resolvedVolumeUUID: { _ in "111" })
    let absent = await unknown.verifySavedRootForRecovery(id, folder: fixture.root, mounts: impostor)
    #expect(absent.classification.cause == .unknown)
    #expect(absent.rootURL == nil)
}

@Test func t229VerifyRetriesSavedBookmarkAfterFailedResolveRemovedPublishedRoot() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let scope = T229Scope(), codec = T229BookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" })
    let id = try await access.grant(folder: fixture.root)
    let originalBytes = try Data(contentsOf: fixture.store.url)
    codec.setFailing(true)
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.probeRootURL(id) }
    #expect(await access.rootURL(id) == nil)
    let mounts = T229Mounts([volume("111")])
    let failed = await access.verifySavedRootForRecovery(id, folder: fixture.child, mounts: mounts)
    #expect(failed.classification.cause != .readable)
    #expect(try Data(contentsOf: fixture.store.url) == originalBytes)
    codec.setFailing(false)
    let recovered = await access.verifySavedRootForRecovery(id, folder: fixture.child, mounts: mounts)
    #expect(recovered.classification.cause == .readable)
    #expect(recovered.rootURL == fixture.root && recovered.folderURL == fixture.child)
    #expect(await access.rootURL(id) == fixture.root)
    #expect(scope.counts.0 == scope.counts.1)
    #expect(try Data(contentsOf: fixture.store.url) == originalBytes)
}

@Test func t229VerifyRequiresStartedScopeContainedFolderAndRealDirectoryListing() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let scope = T229Scope(), codec = T229BookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" })
    let id = try await access.grant(folder: fixture.root)
    let mounts = T229Mounts([volume("111")])
    scope.setAllowed(false)
    let noScope = await access.verifySavedRootForRecovery(id, folder: fixture.child, mounts: mounts)
    #expect(noScope.classification.cause != .readable && noScope.folderURL == nil)
    scope.setAllowed(true)
    let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let escape = await access.verifySavedRootForRecovery(id, folder: outside, mounts: mounts)
    #expect(escape.classification.cause != .readable && escape.folderURL == nil)
    try FileManager.default.removeItem(at: fixture.child)
    let deleted = await access.verifySavedRootForRecovery(id, folder: fixture.child, mounts: mounts)
    #expect(deleted.classification.cause != .readable && deleted.folderURL == nil)
    #expect(scope.counts.0 == scope.counts.1 + 1) // the rejected start is the sole unmatched attempt
}

@Test func t229VerifyRejectsResolvedRootOnDifferentVolumeUUID() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let scope = T229Scope(), codec = T229BookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "333" })
    let id = try await access.grant(folder: fixture.root)
    let verified = await access.verifySavedRootForRecovery(id, folder: fixture.root, mounts: T229Mounts([volume("111")]))
    #expect(verified.classification.cause != .readable)
    #expect(verified.rootURL == nil)
    #expect(scope.counts.0 == scope.counts.1)
}

@Test func t229VerifyRejectsReplacementAtSamePathWithDifferentInode() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let original = FileResourceIdentity(volumeUUID: "111", fileIdentifier: "old-inode")
    let replacement = FileResourceIdentity(volumeUUID: "111", fileIdentifier: "new-inode")
    let scope = T229Scope(), codec = T229BookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        resourceReader: T229IdentityReader(identity: replacement),
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in original })
    let id = try await access.grant(folder: fixture.root)
    let result = await access.verifySavedRootForRecovery(id, folder: fixture.root, mounts: T229Mounts([volume("111")]))
    #expect(result.classification.cause != .readable)
    #expect(result.rootURL == nil && result.folderURL == nil)
    #expect(scope.counts.0 == scope.counts.1)
}

@Test func t229FakeDiskPortCarriesUnmountAndMountUUIDEvents() async throws {
    let port = T229Mounts([volume("111")])
    let stream = await port.events()
    var iterator = stream.makeAsyncIterator()
    await port.set([])
    await port.emit(.unmounted(volume("111")))
    #expect(await iterator.next() == .unmounted(volume("111")))
    await port.set([volume("111")])
    await port.emit(.mounted(volume("111")))
    #expect(await iterator.next() == .mounted(volume("111")))
    #expect(await port.mountedVolumes().map(\.uuid) == ["111"])
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t229SystemDiskMountPortUsesRememberedUUIDOnUnmountAndFreshUUIDOnMount() async {
    let url = URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true)
    let center = NotificationCenter()
    let snapshot = T229MountedSnapshot([volume("111")])
    let port = SystemDiskMountPort(center: center, mountedVolumes: { snapshot.get() })
    let stream = await port.events()
    snapshot.set([])
    center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                userInfo: [NSWorkspace.volumeURLUserInfoKey: url])
    #expect(await nextEvent(in: stream) == .unmounted(volume("111")))
    snapshot.set([volume("333")])
    center.post(name: NSWorkspace.didMountNotification, object: nil,
                userInfo: [NSWorkspace.volumeURLUserInfoKey: url])
    #expect(await nextEvent(in: stream) == .mounted(volume("333")))
    #expect(await port.mountedVolumes().map(\.uuid) == ["333"])
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t229SystemDiskMountPortBuffersEventUntilSubscriberStarts() async {
    let url = URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true)
    let center = NotificationCenter()
    let snapshot = T229MountedSnapshot([volume("111")])
    let port = SystemDiskMountPort(center: center, mountedVolumes: { snapshot.get() })
    snapshot.set([])
    center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                userInfo: [NSWorkspace.volumeURLUserInfoKey: url])
    await Task.yield()
    #expect(await nextEvent(in: await port.events()) == .unmounted(volume("111")))
}

@Test func t229VerifyRebasesSavedChildAfterFailedResolveAndRemountAtNewPath() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let scope = T229Scope(), codec = T229BookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" })
    let id = try await access.grant(folder: fixture.root)
    codec.setFailing(true)
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.probeRootURL(id) }
    #expect(await access.rootURL(id) == nil)
    let newRoot = fixture.base.appendingPathComponent("NewMount/Photos", isDirectory: true)
    let newChild = newRoot.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: newChild, withIntermediateDirectories: true)
    codec.setFailing(false)
    codec.setRelocated(newRoot)
    let recovered = await access.verifySavedRootForRecovery(id, folder: fixture.child,
        mounts: T229Mounts([volume("111", name: "Renamed")]))
    #expect(recovered.classification.cause == .readable)
    #expect(recovered.rootURL == newRoot && recovered.folderURL == newChild)
    #expect(scope.counts.0 == scope.counts.1)
}

@Test func t229OfflineLaunchRetainsOnlyPathHintForLaterRemount() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let codec = T229BookmarkCodec(), scope = T229Scope()
    let id = AccessRootID()
    try fixture.store.save([AccessRootRecord(id: id, bookmark: Data(fixture.root.path.utf8),
        displayName: "Photos", creatingBuildSHA: "old", createdAt: Date())])
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" },
        mountedVolumesProvider: { [] })
    #expect(await access.rootURL(id) == nil)
    #expect(scope.counts == (0, 0))
    let newRoot = fixture.base.appendingPathComponent("NewMount/Photos", isDirectory: true)
    let newChild = newRoot.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: newChild, withIntermediateDirectories: true)
    codec.setRelocated(newRoot)
    let recovered = await access.verifySavedRootForRecovery(id, folder: fixture.child,
        mounts: T229Mounts([volume("111", name: "Renamed")]))
    #expect(recovered.classification.cause == .readable)
    #expect(recovered.rootURL == newRoot && recovered.folderURL == newChild)
    #expect(scope.counts.0 == scope.counts.1)
}

@Test func t229SystemBookmarkCarriesRootIdentityAndLegacyBookmarkDoesNot() throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let bookmark = try SystemSecurityScope().create(for: fixture.root)
    let actual = try URLIdentityResourceReader().identity(for: fixture.root)
    let expected = try #require(actual)
    let saved = try #require(AccessProbeFactGatherer.bookmarkIdentity(in: bookmark))
    #expect(saved == expected)
    let legacy = try fixture.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    // Legacy app bookmarks omitted explicit resource keys. This observed absence
    // is why a safe migration must enrich them while the root remains readable.
    #expect(AccessProbeFactGatherer.bookmarkIdentity(in: legacy) == nil)
    let resolved = try SystemSecurityScope().resolve(bookmark)
    #expect(resolved.url.standardizedFileURL == fixture.root.standardizedFileURL)
}

@Test func t229LegacyBookmarkResolutionAfterOriginalMovesAndPathIsReplaced() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let originalIdentity = try URLIdentityResourceReader().identity(for: fixture.root)
    let original = try #require(originalIdentity)
    let legacy = try fixture.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    let id = AccessRootID()
    let bookmarkVolume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    try fixture.store.save([AccessRootRecord(id: id, bookmark: legacy, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let scope = T229Scope()
    let access = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(),
        store: fixture.store, buildSHA: "T229", mountedVolumesProvider: { [bookmarkVolume] })
    #expect(await access.rootURL(id) != nil)
    let moved = fixture.base.appendingPathComponent("MovedPhotos", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let replacementIdentity = try URLIdentityResourceReader().identity(for: fixture.root)
    let replacement = try #require(replacementIdentity)
    #expect(replacement != original)
    let resolved = try? SystemSecurityScope().resolve(legacy)
    let resolvedIdentity = try resolved.flatMap { try URLIdentityResourceReader().identity(for: $0.url) }
    print("T229 legacy bookmark move-replace: resolved=\(String(describing: resolved?.url.path)) original=\(moved.path) replacement=\(fixture.root.path) identity=\(String(describing: resolvedIdentity))")
    if resolvedIdentity == replacement {
        await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.probeRootURL(id) }
        #expect(await access.rootURL(id) == nil)
        #expect(try fixture.store.load().first?.bookmark == legacy)
        let verification = await access.verifySavedRootForRecovery(id, folder: fixture.root,
            mounts: T229Mounts([bookmarkVolume]))
        #expect(verification.classification.cause == .unknown)
        #expect(verification.rootURL == nil && verification.folderURL == nil)
        #expect(scope.counts.0 == scope.counts.1)
    }
}

@Test func t229MountedLegacyBookmarkKeepsNormalBrowsingWithoutRefresh() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let legacy = try fixture.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let uuid = try #require(volume.uuid)
    let id = AccessRootID()
    try fixture.store.save([AccessRootRecord(id: id, bookmark: legacy, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let scope = T229Scope()
    let resolved = try SystemSecurityScope().resolve(legacy)
    #expect(resolved.url.standardizedFileURL == fixture.root.standardizedFileURL)
    #expect((try? resolved.url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == uuid)
    let access = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: fixture.store,
        buildSHA: "T229", mountedVolumesProvider: { [volume] })
    #expect(await access.records().first?.bookmark == legacy)
    #expect(try fixture.store.load().first?.bookmark == legacy)
    #expect(scope.counts.0 == scope.counts.1)
    #expect(await access.rootURL(id)?.standardizedFileURL == fixture.root.standardizedFileURL)
    #expect(await access.launchOutcomes()[id] == "resolved")
    let probe = try await access.probeRootURL(id)
    #expect(probe.standardizedFileURL == fixture.root.standardizedFileURL)
    let verification = await access.verifySavedRootForRecovery(id, folder: fixture.root,
        mounts: T229Mounts([volume]))
    #expect(verification.classification.cause == .readable)
    #expect(verification.rootURL?.standardizedFileURL == fixture.root.standardizedFileURL)
    #expect(scope.counts.0 == scope.counts.1)
    #expect(uuid == volume.uuid)
}

@Test func t229MountedLegacyBookmarkRecoversAfterTransientScopeFailureInSameSession() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let legacy = try fixture.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let id = AccessRootID()
    try fixture.store.save([AccessRootRecord(id: id, bookmark: legacy, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let scope = T229Scope()
    let access = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(),
        store: fixture.store, buildSHA: "T229", mountedVolumesProvider: { [volume] })
    #expect(await access.rootURL(id) != nil)
    scope.setAllowed(false)
    await #expect(throws: FileAccessError.startFailed) { try await access.probeRootURL(id) }
    scope.setAllowed(true)
    let recovered = await access.verifySavedRootForRecovery(id, folder: fixture.root,
        mounts: T229Mounts([volume]))
    #expect(recovered.classification.cause == .readable)
    #expect(recovered.rootURL?.standardizedFileURL == fixture.root.standardizedFileURL)
    #expect(try fixture.store.load().first?.bookmark == legacy)
    // The denied start has no matching stop; both successful starts do.
    #expect(scope.counts.0 == scope.counts.1 + 1)
}

@Test func t229OfflineLegacyBookmarkStaysUnknownUntilReselected() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let legacy = try fixture.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let id = AccessRootID()
    try fixture.store.save([AccessRootRecord(id: id, bookmark: legacy, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let scope = T229Scope()
    let access = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: fixture.store,
        buildSHA: "T229", mountedVolumesProvider: { [] })
    #expect(try fixture.store.load().first?.bookmark == legacy)
    #expect(scope.counts == (0, 0))
    let offline = await access.verifySavedRootForRecovery(id, folder: fixture.root,
        mounts: T229Mounts([]))
    #expect(offline.classification.cause == .diskNotConnected)
    #expect(offline.rootURL == nil && offline.folderURL == nil)
    let recovered = await access.verifySavedRootForRecovery(id, folder: fixture.root,
        mounts: T229Mounts([volume]))
    #expect(recovered.classification.cause == .unknown)
    #expect(recovered.rootURL == nil && recovered.folderURL == nil)
    #expect(await access.records().first?.bookmark == legacy)
    #expect(try fixture.store.load().first?.bookmark == legacy)
}

private final class T229StaleBookmarkCodec: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0
    var creationCount: Int { lock.withLock { created } }
    func create(for url: URL) throws -> Data {
        lock.withLock { created += 1 }
        return Data(url.path.utf8)
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true),
                         stale: true)
    }
}

@Test func t229OfflineStaleBookmarkDoesNotRefreshAbandonedMountPoint() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let id = AccessRootID()
    let original = Data(fixture.root.path.utf8)
    try fixture.store.save([AccessRootRecord(id: id, bookmark: original, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let scope = T229Scope(), codec = T229StaleBookmarkCodec()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" },
        mountedVolumesProvider: { [] })
    #expect(await access.launchOutcomes()[id] == "failed")
    #expect(codec.creationCount == 0)
    #expect(scope.counts == (0, 0))
    #expect(try fixture.store.load().first?.bookmark == original)
}

@Test func t229StaleLaunchRejectsReplacementBeforeRefreshingSavedIdentity() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let id = AccessRootID()
    let bytes = Data(fixture.root.path.utf8)
    try fixture.store.save([AccessRootRecord(id: id, bookmark: bytes, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let codec = T229StaleBookmarkCodec(), scope = T229Scope()
    let original = FileResourceIdentity(volumeUUID: "111", fileIdentifier: "original")
    let replacement = FileResourceIdentity(volumeUUID: "111", fileIdentifier: "replacement")
    let access = try FileAccess(scope: scope, bookmarks: codec, store: fixture.store, buildSHA: "T229",
        resourceReader: T229IdentityReader(identity: replacement),
        bookmarkVolume: { _ in volume("111") }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in original }, mountedVolumesProvider: { [volume("111")] })
    #expect(await access.rootURL(id) == nil)
    #expect(codec.creationCount == 0)
    #expect(try fixture.store.load().first?.bookmark == bytes)
    #expect(scope.counts.0 == scope.counts.1)
}

@Test func t229ExplicitReselectionReplacesSessionLegacyIdentity() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let legacy = try fixture.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    let savedVolume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let id = AccessRootID()
    try fixture.store.save([AccessRootRecord(id: id, bookmark: legacy, displayName: "Photos",
        creatingBuildSHA: "old", createdAt: Date())])
    let access = try FileAccess(scope: T229Scope(), bookmarks: SystemSecurityScope(), store: fixture.store,
        buildSHA: "T229", mountedVolumesProvider: { [savedVolume] })
    let replacement = fixture.base.appendingPathComponent("Selected", isDirectory: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    _ = try await access.reconnect(id, folder: replacement)
    let actual = try await access.probeRootURL(id)
    #expect(actual.standardizedFileURL == replacement.standardizedFileURL)
    let verification = await access.verifySavedRootForRecovery(id, folder: replacement,
        mounts: T229Mounts([savedVolume]))
    #expect(verification.classification.cause == .readable)
}

private actor T229PausedMounts: DiskMountPort {
    private var waiting: CheckedContinuation<[AccessProbeVolume], Never>?
    var started = false
    func mountedVolumes() async -> [AccessProbeVolume] {
        started = true
        return await withCheckedContinuation { waiting = $0 }
    }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
    func resume() { waiting?.resume(returning: [volume("111")]); waiting = nil }
}

@Test(.timeLimit(.minutes(3))) func t229PendingVerificationCannotOverwriteExplicitReselection() async throws {
    let fixture = try T229Fixture(); defer { fixture.remove() }
    let access = try FileAccess(scope: T229Scope(), bookmarks: T229BookmarkCodec(),
        store: fixture.store, buildSHA: "T229", bookmarkVolume: { _ in volume("111") },
        resolvedVolumeUUID: { _ in "111" })
    let id = try await access.grant(folder: fixture.root)
    let mounts = T229PausedMounts()
    let pending = Task { await access.verifySavedRootForRecovery(id, folder: fixture.root, mounts: mounts) }
    while !(await mounts.started) { try Task.checkCancellation(); await Task.yield() }
    let selected = fixture.base.appendingPathComponent("Selected", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    _ = try await access.reconnect(id, folder: selected)
    await mounts.resume()
    _ = await pending.value
    #expect(await access.rootURL(id) == selected)
    #expect(try fixture.store.load().first?.bookmark == Data(selected.path.utf8))
}
