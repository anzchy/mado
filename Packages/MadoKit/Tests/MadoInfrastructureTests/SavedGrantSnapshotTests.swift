import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private struct T229SavedGrantFixture {
    let base: URL
    let folder: URL
    let store: BookmarkStore
    let codec: FakeBookmarks
    let files: FileAccess
    init(volumeUUID: String? = "111") throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = BookmarkStore(url: base.appendingPathComponent("support/roots.json"))
        let codec = FakeBookmarks()
        self.base = base; self.folder = folder; self.store = store; self.codec = codec
        files = try FileAccess(scope: CountingScope(), bookmarks: codec, store: store, buildSHA: "T229",
            bookmarkVolume: { _ in AccessProbeVolume(uuid: volumeUUID, url: folder, name: "Photos") })
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Test func t229SavedGrantSnapshotCapturesOneRecordVolumeAndLocation() async throws {
    let fixture = try T229SavedGrantFixture(); defer { fixture.remove() }
    let id = try await fixture.files.grant(folder: fixture.folder)
    let snapshot = try #require(await fixture.files.savedGrantSnapshot(id))
    #expect(snapshot.record == (try fixture.store.load().first))
    #expect(snapshot.record.id == id)
    #expect(snapshot.bookmarkVolume == AccessProbeVolume(uuid: "111", url: fixture.folder, name: "Photos"))
    #expect(snapshot.rootURL == fixture.folder)
    #expect(try snapshot.admitting { snapshot.record.bookmark } == Data(fixture.folder.path.utf8))
    #expect(await fixture.files.savedGrantSnapshot(AccessRootID()) == nil)
}

@Test func t229SavedGrantVersionRejectsSameBytesGrantAndExplicitReconnect() async throws {
    let fixture = try T229SavedGrantFixture(); defer { fixture.remove() }
    let id = try await fixture.files.grant(folder: fixture.folder)
    let first = try #require(await fixture.files.savedGrantSnapshot(id))
    #expect(try await fixture.files.grant(folder: fixture.folder) == id)
    let selectedAgain = try #require(await fixture.files.savedGrantSnapshot(id))
    #expect(first.record.bookmark == selectedAgain.record.bookmark)
    var oldUpdateRan = false
    #expect(throws: CancellationError.self) { try first.admitting { oldUpdateRan = true } }
    #expect(!oldUpdateRan)
    #expect(try selectedAgain.admitting { selectedAgain.rootURL } == fixture.folder)
    let other = fixture.base.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    _ = try await fixture.files.reconnect(id, folder: other)
    #expect(throws: CancellationError.self) { try selectedAgain.admitting {} }
    let reconnected = try #require(await fixture.files.savedGrantSnapshot(id))
    #expect(try reconnected.admitting { reconnected.record.bookmark } == Data(other.path.utf8))
    #expect(reconnected.rootURL == other)
}

@Test func t229SavedGrantVersionIsPerRootAndStaleRefreshInvalidatesIt() async throws {
    let fixture = try T229SavedGrantFixture(volumeUUID: nil); defer { fixture.remove() }
    let id = try await fixture.files.grant(folder: fixture.folder)
    let other = fixture.base.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let otherID = try await fixture.files.grant(folder: other)
    let first = try #require(await fixture.files.savedGrantSnapshot(id))
    let unaffected = try #require(await fixture.files.savedGrantSnapshot(otherID))
    fixture.codec.stale = true
    let lease = try await fixture.files.acquire(.root(id, file: fixture.folder))
    await fixture.files.release(lease)
    #expect(throws: CancellationError.self) { try first.admitting {} }
    #expect(try unaffected.admitting { unaffected.rootURL } == other)
    let refreshed = try #require(await fixture.files.savedGrantSnapshot(id))
    #expect(try refreshed.admitting { refreshed.record.id } == id)
    #expect(refreshed.record.bookmark == first.record.bookmark)
}

@Test func t229SavedGrantVersionInvalidatesBeforeFailedPersistence() async throws {
    let fixture = try T229SavedGrantFixture(); defer { fixture.remove() }
    let id = try await fixture.files.grant(folder: fixture.folder)
    let first = try #require(await fixture.files.savedGrantSnapshot(id))
    try FileManager.default.removeItem(at: fixture.store.url)
    try FileManager.default.createDirectory(at: fixture.store.url, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await fixture.files.grant(folder: fixture.folder) }
    #expect(throws: CancellationError.self) { try first.admitting {} }
    #expect(await fixture.files.records().first == first.record)
    let afterFailure = try #require(await fixture.files.savedGrantSnapshot(id))
    #expect(try afterFailure.admitting { afterFailure.record } == first.record)
}
