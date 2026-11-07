import Foundation
import Testing
import MadoCore
import MadoInfrastructure

@Test func accessRecentFoldersPersistNewestTenWithoutBookmarksOrAuthority() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let path = base.appendingPathComponent("recent.json")
    let store = RecentFolderStore(url: path)
    #expect(try await store.load().isEmpty)
    var folders: [RecentFolder] = []
    for n in 0..<12 {
        let folder = RecentFolder(rootID: AccessRootID(), url: base.appendingPathComponent("folder\(n)"), displayName: "folder\(n)")
        folders.append(folder)
        try await store.add(folder)
    }
    let reopened = RecentFolderStore(url: path)
    #expect(try await reopened.load().map(\.displayName) == (2..<12).reversed().map { "folder\($0)" })
    try await reopened.add(folders[3])
    #expect(try await reopened.load().count == 10)
    #expect(try await reopened.load().first == folders[3])
    let regrant = RecentFolder(rootID: AccessRootID(), url: folders[3].url, displayName: "regranted")
    try await reopened.add(regrant)
    #expect(try await reopened.load().count == 10)
    #expect(try await reopened.load().first == regrant)
    try #require(fm.fileExists(atPath: path.path))
    #expect(!String(decoding: try Data(contentsOf: path), as: UTF8.self).contains("bookmark"))
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(), store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "new")
    #expect(await access.rootCovering(folders[3].url) == nil)
}

@Test func accessCorruptRecentStorePreservesEvidenceAndRecoversAcrossRelaunch() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("recent-folders.json")
    let recovery = path.appendingPathExtension("recovered")
    let corrupt = Data("invalid recent contents".utf8)
    try corrupt.write(to: path)
    let store = RecentFolderStore(url: path)
    #expect(try await store.load().isEmpty)
    #expect(await store.storeCorrupt)
    let folder = RecentFolder(rootID: AccessRootID(), url: base, displayName: "photos")
    try await store.add(folder)
    #expect(try Data(contentsOf: path) == corrupt)
    #expect(try await store.load() == [folder])
    #expect(fm.fileExists(atPath: recovery.path))
    let relaunched = RecentFolderStore(url: path)
    #expect(try await relaunched.load() == [folder])
    #expect(await relaunched.storeCorrupt)
    #expect(try Data(contentsOf: path) == corrupt)
    #expect(!String(decoding: try Data(contentsOf: recovery), as: UTF8.self).contains("bookmark"))
}

@Test func accessIncompatibleRecentAndCorruptRecoveryStillAllowFreshRecents() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("recent-folders.json")
    let recovery = path.appendingPathExtension("recovered")
    let incompatible = Data("{\"schema\":999}".utf8)
    let brokenRecovery = Data("broken recovery".utf8)
    try incompatible.write(to: path)
    try brokenRecovery.write(to: recovery)
    let store = RecentFolderStore(url: path)
    #expect(try await store.load().isEmpty)
    #expect(await store.storeCorrupt)
    #expect(try Data(contentsOf: path) == incompatible)
    #expect(try Data(contentsOf: recovery) == brokenRecovery)
    let folder = RecentFolder(rootID: AccessRootID(), url: base, displayName: "fresh")
    try await store.add(folder)
    #expect(try await RecentFolderStore(url: path).load() == [folder])
    #expect(try Data(contentsOf: path) == incompatible)
}
