import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private struct T229CoverageFixture {
    let base: URL
    let root: URL
    let store: BookmarkStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("Photos", isDirectory: true)
        store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func save(_ bookmark: Data, id: AccessRootID) throws {
        try store.save([AccessRootRecord(id: id, bookmark: bookmark, displayName: "Photos",
            creatingBuildSHA: "old", createdAt: Date(timeIntervalSince1970: 1))])
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
private struct T229CoverageNoIdentity: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { nil }
}
private actor T229CoverageMounts: DiskMountPort {
    let volumes: [AccessProbeVolume]
    init(_ volumes: [AccessProbeVolume]) { self.volumes = volumes }
    func mountedVolumes() -> [AccessProbeVolume] { volumes }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}

@Test func t229AdditionalLaunchNeverPublishesUnknownOrWrongVolume() async throws {
    for unknown in [false, true] {
        let f = try T229CoverageFixture(); defer { f.remove() }
        let id = AccessRootID(), scope = CountingScope()
        let bookmark = try SystemSecurityScope().create(for: f.root)
        try f.save(bookmark, id: id)
        let savedBytes = try Data(contentsOf: f.store.url)
        let volume = AccessProbeVolume(uuid: unknown ? nil : "saved", url: nil, name: "Photos")
        let files = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: f.store, buildSHA: "T229",
            bookmarkVolume: { _ in volume }, resolvedVolumeUUID: { _ in "different" },
            mountedVolumesProvider: { [volume] })
        #expect(await files.rootURL(id) == nil)
        #expect(await files.launchOutcomes()[id] == "failed")
        #expect(await files.savedVolume(id) == volume)
        #expect(await files.savedVolume(AccessRootID()) == nil)
        #expect(scope.counts == [0, 0])
        #expect(try Data(contentsOf: f.store.url) == savedBytes)
    }
}

@Test func t229AdditionalMountedLegacyNeedsObservedRootIdentity() async throws {
    let f = try T229CoverageFixture(); defer { f.remove() }
    let id = AccessRootID(), scope = CountingScope()
    let legacy = try f.root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    try f.save(legacy, id: id)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let files = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: f.store, buildSHA: "T229",
        resourceReader: T229CoverageNoIdentity(), mountedVolumesProvider: { [volume] })
    #expect(await files.rootURL(id) == nil)
    #expect(await files.launchOutcomes()[id] == "failed")
    #expect(try f.store.load().first?.bookmark == legacy)
    #expect(scope.counts == [1, 1])
}

@Test func t229AdditionalStaleLaunchListsMountedRootBeforePublishing() async throws {
    for directory in [false, true] {
        let f = try T229CoverageFixture(); defer { f.remove() }
        let target = directory ? f.root : f.base.appendingPathComponent("plain-file")
        if !directory { try Data("not a directory".utf8).write(to: target) }
        let identity = try #require(try URLIdentityResourceReader().identity(for: target))
        let volume = AccessProbeVolume(uuid: identity.volumeUUID, url: nil, name: "Photos")
        let codec = FakeBookmarks(), scope = CountingScope(), id = AccessRootID()
        let bookmark = try codec.create(for: target)
        try f.save(bookmark, id: id)
        codec.stale = true
        let files = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229",
            bookmarkVolume: { _ in volume }, bookmarkIdentity: { _ in identity },
            mountedVolumesProvider: { [volume] })
        #expect(await files.rootURL(id) == (directory ? target : nil))
        #expect(await files.launchOutcomes()[id] == (directory ? "stale" : "failed"))
        #expect(try f.store.load().first?.bookmark == bookmark)
        #expect(codec.count == (directory ? 2 : 1))
        #expect(scope.counts == [1, 1])
    }
}

@Test func t229AdditionalUnknownRecoveryCannotMintRootOrVolume() async throws {
    let f = try T229CoverageFixture(); defer { f.remove() }
    let scope = CountingScope()
    let files = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: f.store, buildSHA: "T229")
    let result = await files.verifySavedRootForRecovery(AccessRootID(), folder: f.root, mounts: T229CoverageMounts([]))
    #expect(result.classification.cause == .unknown)
    #expect(!result.classification.isInTrash)
    #expect(result.rootURL == nil && result.folderURL == nil)
    #expect(result.bookmarkVolume == AccessProbeVolume(uuid: nil, url: nil, name: nil))
    #expect(scope.counts == [0, 0])
    #expect(await files.records().isEmpty)
}

@Test func t229AdditionalLiveStaleRefreshRequiresMountedSameRoot() async throws {
    for mode in ["readable", "offline", "replacement"] {
        let f = try T229CoverageFixture(); defer { f.remove() }
        let original = try #require(try URLIdentityResourceReader().identity(for: f.root))
        let volume = AccessProbeVolume(uuid: original.volumeUUID, url: nil, name: "Photos")
        let scope = CountingScope(), codec = FakeBookmarks()
        let files = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229",
            bookmarkVolume: { _ in volume }, bookmarkIdentity: { _ in original },
            mountedVolumesProvider: { mode == "offline" ? [] : [volume] })
        let id = try await files.grant(folder: f.root)
        let before = try Data(contentsOf: f.store.url)
        if mode == "replacement" {
            try FileManager.default.moveItem(at: f.root, to: f.base.appendingPathComponent("original-root"))
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        }
        codec.stale = true
        if mode == "readable" {
            #expect(try await files.probeRootURL(id) == f.root)
            #expect(await files.rootURL(id) == f.root)
            #expect(codec.count == 2)
        } else {
            await #expect(throws: FileAccessError.needsReconnection(id)) { try await files.probeRootURL(id) }
            #expect(await files.rootURL(id) == nil)
            #expect(codec.count == 1)
            #expect(try Data(contentsOf: f.store.url) == before)
        }
        #expect(scope.counts[0] == scope.counts[1])
    }
}

@Test func t229AdditionalFreshOriginKeepsBothPinnedBuffersUntilLastRelease() async throws {
    let authority = AccessWorkAuthority(), memory = ImageMemoryCache(capacity: 1_000_000)
    let pipeline = ImageIOPipeline(cache: memory)
    authority.update(counter: 0, readable: true)
    let raw = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
    let oldRequest = ImageDecodeRequest(fileURL: raw.fileURL, maximumPixelSize: raw.maximumPixelSize,
        renderKey: raw.renderKey, accessPermit: authority.permit(counter: 0))
    let old = try await pipeline.image(for: oldRequest)
    let key = try #require(raw.renderKey)
    await pipeline.pin(key, image: old)
    let oldVariant = try await pipeline.imageFresh(for: oldRequest)
    #expect(oldVariant.image !== old.image)
    await pipeline.pin(key, image: oldVariant)
    authority.update(counter: 1, readable: false)
    authority.update(counter: 1, readable: true)
    let freshRequest = ImageDecodeRequest(fileURL: raw.fileURL, maximumPixelSize: raw.maximumPixelSize,
        renderKey: raw.renderKey, accessPermit: authority.permit(counter: 1))
    let fresh = try await pipeline.imageFresh(for: freshRequest)
    #expect(old.image !== fresh.image)
    await pipeline.pin(key, image: fresh)
    await pipeline.pin(key, image: fresh)
    let total = old.image.bytesPerRow * old.image.height + oldVariant.image.bytesPerRow * oldVariant.image.height
        + fresh.image.bytesPerRow * fresh.image.height
    #expect(await memory.usage().pinnedBytes == total)
    #expect(await memory.usage().totalBytes == total)
    #expect(try await pipeline.image(for: freshRequest).image === fresh.image)
    await pipeline.unpin(key)
    await pipeline.unpin(key)
    await pipeline.unpin(key)
    #expect(await memory.usage().pinnedBytes == total)
    await pipeline.unpin(key)
    #expect(await memory.usage().pinnedBytes == 0)
    #expect(await memory.usage().totalBytes == fresh.image.bytesPerRow * fresh.image.height)
    #expect(try await pipeline.image(for: freshRequest).image === fresh.image)
}

@Test func t229AdditionalStorePreservesRealSourcePermissionFailureBeforeAndAfterPayload() async throws {
    for afterPayload in [false, true] {
        let f = try T229CoverageFixture(); defer { f.remove() }
        let file = f.root.appendingPathComponent("image.tiff")
        try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let pipeline = ImageIOPipeline()
        let raw = try await pipeline.request(for: file, maximumPixelSize: 64,
            identityRoot: ItemIdentityRoot(id: AccessRootID(), url: f.root))
        let image = try await pipeline.image(for: raw)
        let cache = ThumbnailDiskCache(directory: f.base.appendingPathComponent("cache"), afterPayloadWrite: {
            if afterPayload { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path) }
        })
        let ticket = try #require(try await cache.prepare(raw))
        if !afterPayload { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path) }
        do { try await cache.store(image, for: ticket); Issue.record("source permission failure was suppressed") }
        catch { #expect(AccessReadFailure.isPermissionDenied(error)) }
        #expect(await cache.diagnostics().entries == 0)
        #expect(await cache.writeDiagnostics().failureCount == 0)
        #expect(await cache.writeDiagnostics().lastFailure == nil)
    }
}

@Test func t229MountedLegacyNormalReadKeepsObservedIdentityAndOriginalBookmark() async throws {
    let f = try T229CoverageFixture(); defer { f.remove() }
    let file = f.root.appendingPathComponent("readable.txt")
    let expected = Data("legacy session remains readable".utf8)
    try expected.write(to: file)
    let id = AccessRootID(), scope = CountingScope()
    let legacy = try f.root.bookmarkData(options: [.withSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    try f.save(legacy, id: id)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let files = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: f.store,
        buildSHA: "T229-legacy-normal", mountedVolumesProvider: { [volume] })
    #expect(await files.rootURL(id) != nil)
    let observed = try await files.withLease(.root(id, file: file)) { lease in
        #expect(lease.rootID == id)
        return try Data(contentsOf: file)
    }
    #expect(observed == expected)
    #expect(try f.store.load().first?.bookmark == legacy)
    #expect(scope.counts == [2, 2])
}
