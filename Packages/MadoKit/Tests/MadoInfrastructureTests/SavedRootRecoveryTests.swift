import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private struct T229SavedRootFixture {
    let base: URL
    let root: URL
    let store: BookmarkStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("Photos/chosen", isDirectory: true)
        store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func save(_ bookmark: Data, id: AccessRootID) throws {
        try store.save([AccessRootRecord(id: id, bookmark: bookmark, displayName: "chosen",
            creatingBuildSHA: "old", createdAt: Date(timeIntervalSince1970: 1))])
    }
    func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
private actor T229SavedRootMounts: DiskMountPort {
    let volumes: [AccessProbeVolume]
    init(_ volumes: [AccessProbeVolume]) { self.volumes = volumes }
    func mountedVolumes() -> [AccessProbeVolume] { volumes }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}

@Test func t229RootOnlyVerificationRecoversOfflineEnrichedSavedFolderNotVolumeURL() async throws {
    let f = try T229SavedRootFixture(); defer { f.remove() }
    let bookmark = try SystemSecurityScope().create(for: f.root)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: bookmark)
    let mountURL = try #require(volume.url)
    #expect(f.canonical(mountURL) != f.canonical(f.root))
    let id = AccessRootID(), scope = CountingScope()
    try f.save(bookmark, id: id)
    let bytes = try Data(contentsOf: f.store.url)
    let files = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: f.store,
        buildSHA: "T229-WI5", mountedVolumesProvider: { [] })
    #expect(await files.rootURL(id) == nil)
    #expect(scope.counts == [0, 0])
    let result = await files.verifySavedRootForRecovery(id, mounts: T229SavedRootMounts([volume]))
    #expect(result.classification.cause == .readable)
    let root = try #require(result.rootURL), folder = try #require(result.folderURL)
    #expect(f.canonical(root) == f.canonical(f.root))
    #expect(f.canonical(folder) == f.canonical(f.root))
    #expect(result.bookmarkVolume == volume)
    #expect(scope.counts == [1, 1])
    #expect(try Data(contentsOf: f.store.url) == bytes)
}

@Test func t229RootOnlyVerificationRetriesSavedBytesAfterFailedResolveAndRejectsWrongUUID() async throws {
    let f = try T229SavedRootFixture(); defer { f.remove() }
    let id = AccessRootID(), scope = CountingScope(), codec = FakeBookmarks()
    let bookmark = try codec.create(for: f.root)
    try f.save(bookmark, id: id)
    let volume = AccessProbeVolume(uuid: "111", url: f.base, name: "same-name")
    codec.fails = true
    let files = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229-WI5",
        bookmarkVolume: { _ in volume }, resolvedVolumeUUID: { _ in "111" },
        mountedVolumesProvider: { [volume] })
    #expect(await files.rootURL(id) == nil)
    let bytes = try Data(contentsOf: f.store.url)
    let wrong = await files.verifySavedRootForRecovery(id,
        mounts: T229SavedRootMounts([.init(uuid: "different", url: f.base, name: "same-name")]))
    #expect(wrong.classification.cause == .diskNotConnected)
    #expect(wrong.rootURL == nil && wrong.folderURL == nil)
    let failed = await files.verifySavedRootForRecovery(id, mounts: T229SavedRootMounts([volume]))
    #expect(failed.classification.cause != .readable)
    codec.fails = false
    let recovered = await files.verifySavedRootForRecovery(id, mounts: T229SavedRootMounts([volume]))
    #expect(recovered.classification.cause == .readable)
    #expect(recovered.rootURL == f.root && recovered.folderURL == f.root)
    #expect(scope.counts[0] == scope.counts[1])
    #expect(try Data(contentsOf: f.store.url) == bytes)
}

@Test func t229RootOnlyVerificationKeepsOfflineLegacyUnknownAfterMatchingMount() async throws {
    let f = try T229SavedRootFixture(); defer { f.remove() }
    let legacy = try f.root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    #expect(AccessProbeFactGatherer.bookmarkIdentity(in: legacy) == nil)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: legacy)
    let id = AccessRootID(), scope = CountingScope()
    try f.save(legacy, id: id)
    let files = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(), store: f.store,
        buildSHA: "T229-WI5", mountedVolumesProvider: { [] })
    #expect(await files.rootURL(id) == nil)
    let verified = await files.verifySavedRootForRecovery(id, mounts: T229SavedRootMounts([volume]))
    #expect(verified.classification.cause == .unknown)
    #expect(verified.rootURL == nil && verified.folderURL == nil)
    #expect(try f.store.load().first?.bookmark == legacy)
    #expect(scope.counts == [0, 0])
}

@MainActor @Test func t229RootRecoveryCannotCommitAcrossExplicitGrantVersionChange() async throws {
    let f = try T229SavedRootFixture(); defer { f.remove() }
    let scope = CountingScope(), codec = FakeBookmarks()
    let volume = AccessProbeVolume(uuid: "111", url: f.base, name: "Photos")
    let files = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T229-WI5",
        bookmarkVolume: { _ in volume }, resolvedVolumeUUID: { _ in "111" })
    let id = try await files.grant(folder: f.root)
    let state = AccessState()
    state.register(id, volumeUUID: "111")
    state.diskUnmounted(volumeUUID: "111")
    let attempt = try #require(state.diskMounted(volumeUUID: "111").first)
    let grant = try #require(await files.savedGrantSnapshot(id))
    let verified = await files.verifySavedRootForRecovery(id, mounts: T229SavedRootMounts([volume]))
    try #require(verified.classification.cause == .readable)
    _ = try await files.grant(folder: f.root)
    var events: [AccessStateChange] = []
    _ = state.observe { events.append($0) }
    #expect(throws: CancellationError.self) {
        try state.completeRecovery(attempt, verified: true, admitting: { update in try grant.admitting(update) })
    }
    #expect(state.snapshot(for: id)?.availability == .lost(.diskNotConnected))
    #expect(state.snapshot(for: id)?.counter == 1)
    #expect(state.permit(for: id) == nil && events.isEmpty)
    #expect(scope.counts[0] == scope.counts[1])
}
