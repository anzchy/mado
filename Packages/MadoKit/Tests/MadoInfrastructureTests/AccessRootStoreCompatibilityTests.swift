import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func p201CompatibilityLiteralP0JSONDecodesEveryField() throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let store = BookmarkStore(url: f.base.appendingPathComponent("legacy-roots.json"))
    let json = """
    [{"id":{"rawValue":"11111111-2222-4333-8444-555555555555"},"bookmark":"L3RtcC9sZWdhY3k=","displayName":"legacy","creatingBuildSHA":"P0","createdAt":0}]
    """
    try Data(json.utf8).write(to: store.url)
    let records = try store.load()
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.id.rawValue == UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
    #expect(record.bookmark == Data("/tmp/legacy".utf8))
    #expect(record.displayName == "legacy")
    #expect(record.creatingBuildSHA == "P0")
    #expect(record.createdAt == Date(timeIntervalSinceReferenceDate: 0))
}

@Test(.timeLimit(.minutes(2))) func p201CompatibilityLegacyReconnectDedupAndFreshInstancePreserveIdentity() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    try FileManager.default.createDirectory(at: f.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let oldBookmark = Data(f.old.path.utf8)
    let json = """
    [{"id":{"rawValue":"11111111-2222-4333-8444-555555555555"},"bookmark":"\(oldBookmark.base64EncodedString())","displayName":"old","creatingBuildSHA":"P0","createdAt":0}]
    """
    try Data(json.utf8).write(to: f.store.url)
    let id = AccessRootID(rawValue: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "repair")
    #expect(try await access.reconnect(id, folder: f.chosen) == f.chosen)
    #expect(try await access.grant(folder: f.chosen) == id)
    let records = try f.store.load()
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.id == id)
    #expect(record.bookmark == Data(f.chosen.path.utf8))
    #expect(record.bookmark != oldBookmark)
    #expect(record.displayName == "new")
    #expect(record.creatingBuildSHA == "P0")
    #expect(record.createdAt == Date(timeIntervalSinceReferenceDate: 0))
    let fresh = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "fresh")
    #expect(await fresh.records() == records)
    #expect(await fresh.rootURL(id) == f.chosen)
    let lease = try await fresh.acquire(.root(id, file: f.chosen.appendingPathComponent("a.png")))
    #expect(lease.url == f.chosen && lease.rootID == id)
    await fresh.release(lease)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: ["absent", "valid", "corrupt"])
func p201CompatibilityRecoveryReconnectPreservesCorruptPrimaryAndFileGrants(recovery: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    try FileManager.default.createDirectory(at: f.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let primary = Data("broken-primary".utf8)
    try primary.write(to: f.store.url)
    let recoveryURL = f.store.url.appendingPathExtension("recovered")
    let otherID = AccessRootID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!)
    if recovery == "valid" {
        let json = """
        [{"id":{"rawValue":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"},"bookmark":"\(Data(f.old.path.utf8).base64EncodedString())","displayName":"old","creatingBuildSHA":"P0","createdAt":0}]
        """
        try Data(json.utf8).write(to: recoveryURL)
    } else if recovery == "corrupt" { try Data("broken-recovery".utf8).write(to: recoveryURL) }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "repair")
    #expect(await access.storeCorrupt)
    let initialRecords = await access.records()
    #expect(initialRecords.count == (recovery == "valid" ? 1 : 0))
    let initialRecoveryBytes = try? Data(contentsOf: recoveryURL)
    let file = f.chosen.appendingPathComponent("a.png")
    let fileLease = try await access.acquire(.fileGrant(file))
    #expect(fileLease.rootID == nil && fileLease.url == file)
    await access.release(fileLease)
    #expect(await access.records() == initialRecords)
    #expect(try Data(contentsOf: f.store.url) == primary)
    #expect((try? Data(contentsOf: recoveryURL)) == initialRecoveryBytes)
    #expect(codec.count == 1) // Session-only File Grant bookmark; root store bytes remain unchanged.
    let missingID = AccessRootID(rawValue: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
    let recent = RecentFolder(rootID: missingID,
        url: f.base.appendingPathComponent("unavailable", isDirectory: true), displayName: "old-reference")
    #expect(try await access.reconnect(recent.rootID, folder: f.chosen) == f.chosen)
    #expect(try Data(contentsOf: f.store.url) == primary)
    let repaired = try BookmarkStore(url: recoveryURL).load()
    #expect(repaired.count == (recovery == "valid" ? 2 : 1))
    let record = try #require(repaired.first { $0.id == missingID })
    #expect(record.bookmark == Data(f.chosen.path.utf8))
    #expect(record.displayName == "new" && record.creatingBuildSHA == "repair")
    if recovery == "valid" {
        #expect(repaired.first { $0.id == otherID } == initialRecords.first { $0.id == otherID })
    }
    let fresh = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "fresh")
    #expect(await fresh.storeCorrupt)
    #expect(await fresh.records() == repaired)
    let restored = try await fresh.acquire(.root(missingID, file: file))
    #expect(restored.url == f.chosen && restored.rootID == missingID)
    await fresh.release(restored)
    #expect(try Data(contentsOf: f.store.url) == primary)
    #expect(scope.balanced)
}
