import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func p201RootStoreCanonicalGrantsRefreshOneRoot() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = ReconnectBookmarks(); let scope = ReconnectScope()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let first = try await access.grant(folder: f.old)
    let original = try #require(f.store.load().first)
    let alias = f.base.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.old)
    var bookmark = original.bookmark
    for selected in [f.old, URL(fileURLWithPath: f.old.path + "/", isDirectory: true), alias] {
        #expect(try await access.grant(folder: selected) == first)
        let records = try f.store.load()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == first)
        #expect(record.bookmark != bookmark)
        #expect(try codec.resolve(record.bookmark).url == f.old)
        #expect(record.creatingBuildSHA == original.creatingBuildSHA && record.createdAt == original.createdAt)
        bookmark = record.bookmark
    }
    #expect(codec.count == 4)
    let lease = try await access.acquire(.root(first, file: f.old.appendingPathComponent("a.png")))
    #expect(lease.url == f.old && lease.rootID == first)
    await access.release(lease)
    #expect(scope.balanced)
}

@Test(arguments: [false, true])
func p201RootStoreParentChildAndPrefixStayDistinct(parentFirst: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let photos = f.base.appendingPathComponent("photos", isDirectory: true)
    let sibling = f.base.appendingPathComponent("photos-extra", isDirectory: true)
    let child = photos.appendingPathComponent("child", isDirectory: true)
    for folder in [photos, sibling, child] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let folders = parentFirst ? [f.base, photos, child, sibling] : [child, photos, sibling, f.base]
    var ids: [AccessRootID] = []
    for folder in folders { ids.append(try await access.grant(folder: folder)) }
    #expect(Set(ids).count == 4)
    #expect(try f.store.load().count == 4)
    for (folder, id) in zip(folders, ids) {
        #expect(try await access.grant(folder: folder) == id)
        let record = try #require(f.store.load().first { $0.id == id })
        #expect(try codec.resolve(record.bookmark).url == folder)
    }
    #expect(try f.store.load().count == 4)
    #expect(scope.balanced)
}

@Test func p201RootStoreGrantDoesNotReviveUnresolvedRecord() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let first = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let oldID = try await first.grant(folder: f.old)
    let original = try #require(f.store.load().first)
    codec.failingBookmarks = [original.bookmark]
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    let newID = try await access.grant(folder: f.old)
    #expect(newID != oldID)
    #expect(try f.store.load().count == 2)
    #expect(try f.store.load().first { $0.id == oldID } == original)
    await #expect(throws: FileAccessError.needsReconnection(oldID)) { try await access.acquire(.root(oldID, file: f.old)) }
    let lease = try await access.acquire(.root(newID, file: f.old))
    #expect(lease.url == f.old && lease.rootID == newID)
    await access.release(lease)
    #expect(scope.balanced)
}

@Test(arguments: ["bookmark", "save"])
func p201RootStoreDuplicateFailurePreservesAuthorization(kind: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    let support = f.store.url.deletingLastPathComponent()
    if kind == "bookmark" { codec.creationFails = true }
    if kind == "save" { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path) }
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path) }
    if kind == "bookmark" {
        await #expect(throws: ReconnectTestError.bookmark) { try await access.grant(folder: f.old) }
    } else {
        await #expect(throws: CocoaError.self) { try await access.grant(folder: f.old) }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
    codec.creationFails = false
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(await access.records() == records)
    let lease = try await access.acquire(.root(id, file: f.old))
    #expect(lease.url == f.old && lease.rootID == id)
    await access.release(lease)
    #expect(scope.balanced)
}

@Test func p201RootStoreReusedGrantReplacesRecentEntry() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let recent = RecentFolderStore(url: f.base.appendingPathComponent("recent.json"))
    let id = try await access.grant(folder: f.old)
    let old = RecentFolder(rootID: id, url: f.old, displayName: "old", openedAt: Date(timeIntervalSinceReferenceDate: 10))
    try await recent.add(old)
    let controlID = try await access.grant(folder: f.chosen)
    let control = RecentFolder(rootID: controlID, url: f.chosen, displayName: "control", openedAt: Date(timeIntervalSinceReferenceDate: 15))
    try await recent.add(control)
    let alias = f.base.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.old)
    let reused = try await access.grant(folder: alias)
    #expect(reused == id)
    let latest = RecentFolder(rootID: reused, url: alias, displayName: "photos", openedAt: Date(timeIntervalSinceReferenceDate: 20))
    try await recent.add(latest)
    #expect(try await recent.load() == [latest, control])
    #expect(scope.balanced)
}

@Test(arguments: [false, true])
func p201RootStoreGrantUsesPostScopeSymlinkIdentity(reuse: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let original = try #require(f.store.load().first)
    let alias = f.base.appendingPathComponent("selection", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: reuse ? f.chosen : f.old)
    scope.beforeStart = { url in
        guard url == alias else { return }
        try? FileManager.default.removeItem(at: alias)
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: reuse ? f.old : f.chosen)
    }
    let result = try await access.grant(folder: alias)
    let records = try f.store.load()
    let record = try #require(records.first { $0.id == result })
    if reuse {
        #expect(result == id)
        #expect(records.count == 1)
        #expect(record.bookmark != original.bookmark)
        #expect(try codec.resolve(record.bookmark).url == f.old)
    } else {
        #expect(result != id)
        #expect(records.count == 2)
        #expect(records.first { $0.id == id } == original)
        #expect(try codec.resolve(record.bookmark).url == f.chosen)
    }
    let destination = reuse ? f.old : f.chosen
    let lease = try await access.acquire(.root(result, file: destination))
    #expect(lease.url == destination && lease.rootID == result)
    await access.release(lease)
    #expect(scope.balanced)
}

private final class RootStoreVisibilityScope: SecurityScope, @unchecked Sendable {
    let alias: URL
    let destination: URL
    let counts = ReconnectScope()
    init(alias: URL, destination: URL) { self.alias = alias; self.destination = destination }
    func start(_ url: URL) -> Bool {
        if url == alias { try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination) }
        return counts.start(url)
    }
    func stop(_ url: URL) {
        counts.stop(url)
        if url == alias { try? FileManager.default.removeItem(at: alias) }
    }
    func isReadable(_ url: URL) -> Bool { false }
}

@Test func p201RootStoreOtherRootCanonicalizationHasItsOwnScope() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let alias = f.base.appendingPathComponent("visible-in-scope", isDirectory: true)
    let scope = RootStoreVisibilityScope(alias: alias, destination: f.old)
    let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: alias)
    #expect(FileManager.default.fileExists(atPath: alias.path) == false)
    #expect(try await access.grant(folder: f.old) == id)
    let records = try f.store.load()
    #expect(records.count == 1)
    #expect(records.first?.id == id)
    let record = try #require(records.first)
    #expect(try codec.resolve(record.bookmark).url == f.old)
    #expect(FileManager.default.fileExists(atPath: alias.path) == false)
    #expect(scope.counts.balanced)
}

@Test(arguments: ["grant", "reconnect", "selected-denied"])
func p201RootStoreUnrelatedDeniedRootDoesNotBlockExplicitSelection(action: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let oldID = try await access.grant(folder: f.old)
    let original = try #require(f.store.load().first)
    let bytes = try Data(contentsOf: f.store.url)
    let suppliedID = AccessRootID()
    scope.rejected = action == "selected-denied" ? f.chosen : f.old
    if action == "selected-denied" {
        await #expect(throws: FileAccessError.startFailed) { try await access.grant(folder: f.chosen) }
        await #expect(throws: FileAccessError.startFailed) { try await access.reconnect(suppliedID, folder: f.chosen) }
        #expect(try Data(contentsOf: f.store.url) == bytes)
        #expect(await access.records() == [original])
        #expect(scope.counts(f.chosen) == [0, 0, 2])
    } else {
        let selectedID: AccessRootID
        if action == "grant" { selectedID = try await access.grant(folder: f.chosen) }
        else {
            #expect(try await access.reconnect(suppliedID, folder: f.chosen) == f.chosen)
            selectedID = suppliedID
        }
        #expect(selectedID != oldID)
        #expect(try f.store.load().count == 2)
        #expect(try f.store.load().first { $0.id == oldID } == original)
        #expect(scope.counts(f.old) == [1, 1, 1])
        let lease = try await access.acquire(.root(selectedID, file: f.chosen))
        #expect(lease.url == f.chosen && lease.rootID == selectedID)
        await access.release(lease)
    }
    scope.rejected = nil
    let oldLease = try await access.acquire(.root(oldID, file: f.old))
    #expect(oldLease.url == f.old && oldLease.rootID == oldID)
    await access.release(oldLease)
    #expect(scope.balanced)
}
