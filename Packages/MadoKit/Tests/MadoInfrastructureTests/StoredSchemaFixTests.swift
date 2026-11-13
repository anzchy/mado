import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private func fixDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test(.timeLimit(.minutes(2))) func t216FixDowngradeReupgradeArraysAndLegacyRecentFixture() async throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let rootPath = base.appendingPathComponent("roots.json")
    let roots = BookmarkStore(url: rootPath)
    let first = AccessRootRecord(id: AccessRootID(), bookmark: Data("one".utf8), displayName: "one", creatingBuildSHA: "new", createdAt: .init(timeIntervalSinceReferenceDate: 0))
    try roots.save([first])
    var oldRoots = try JSONDecoder().decode([AccessRootRecord].self, from: Data(contentsOf: rootPath))
    #expect(oldRoots == [first])
    let second = AccessRootRecord(id: AccessRootID(), bookmark: Data("two".utf8), displayName: "two", creatingBuildSHA: "old", createdAt: .init(timeIntervalSinceReferenceDate: 1))
    oldRoots.append(second)
    try JSONEncoder().encode(oldRoots).write(to: rootPath)
    #expect(try roots.load() == [first, second])
    try roots.save([first, second])
    #expect(try JSONDecoder().decode([AccessRootRecord].self, from: Data(contentsOf: rootPath)) == [first, second])

    let recentPath = base.appendingPathComponent("recent.json")
    let recent = RecentFolderStore(url: recentPath)
    let newFolder = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/tmp/new"), displayName: "new", openedAt: .init(timeIntervalSinceReferenceDate: 1))
    try await recent.add(newFolder)
    var oldRecent = try JSONDecoder().decode([RecentFolder].self, from: Data(contentsOf: recentPath))
    #expect(oldRecent == [newFolder])
    let literal = Data(#"[{"rootID":{"rawValue":"11111111-2222-4333-8444-555555555555"},"url":"file:\/\/\/tmp\/legacy","displayName":"legacy","openedAt":0}]"#.utf8)
    let legacy = try #require(JSONDecoder().decode([RecentFolder].self, from: literal).first)
    #expect(legacy.displayName == "legacy")
    oldRecent.append(legacy)
    try JSONEncoder().encode(oldRecent).write(to: recentPath)
    #expect(try await recent.load() == [newFolder, legacy])
    try await recent.add(legacy)
    #expect(try JSONDecoder().decode([RecentFolder].self, from: Data(contentsOf: recentPath)).contains(newFolder))
}

@Test(.timeLimit(.minutes(2))) @MainActor func t216FixDowngradeReupgradeDisplayPreferences() throws {
    let suite = "mado.schema.fix.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "displayPreferences.v1"
    let current = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    current.value = DisplayPreferences(appearance: .dark)
    var old = try JSONDecoder().decode(DisplayPreferences.self, from: #require(defaults.data(forKey: key)))
    #expect(old.appearance == .dark)
    old.appearance = .light
    defaults.set(try JSONEncoder().encode(old), forKey: key)
    #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value.appearance == .light)
}

@Test(.timeLimit(.minutes(2))) func t216FixExplicitNullPersonalVersionIsCorrupt() async throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("personal.json")
    let bytes = Data(#"{"version":null,"favorites":[],"recents":[]}"#.utf8)
    try bytes.write(to: path)
    let store = PersonalImageStore(url: path)
    #expect(try await store.favorites().isEmpty)
    #expect(await store.storeCorrupt)
    #expect(try Data(contentsOf: path) == bytes)
}

@Test(.timeLimit(.minutes(2))) func t216FixUnsupportedRootsAllowSessionGrantAndRecent() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    try FileManager.default.createDirectory(at: f.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let futureRoots = Data(#"{"schemaVersion":99,"items":[{"future":true}]}"#.utf8)
    try futureRoots.write(to: f.store.url)
    let access = try FileAccess(scope: ReconnectScope(), bookmarks: ReconnectBookmarks(), store: f.store, buildSHA: "new")
    let id = try await access.grant(folder: f.old)
    #expect(await access.records().map(\.id) == [id])
    #expect(await access.rootURL(id) == f.old)
    #expect(try Data(contentsOf: f.store.url) == futureRoots)
    let relaunched = try FileAccess(scope: ReconnectScope(), bookmarks: ReconnectBookmarks(), store: f.store, buildSHA: "new")
    #expect(await relaunched.records().isEmpty)

    let recentPath = f.base.appendingPathComponent("recent.json")
    let futureRecent = Data(#"{"schemaVersion":99,"items":[{"future":true}]}"#.utf8)
    try futureRecent.write(to: recentPath)
    let recent = RecentFolderStore(url: recentPath)
    let folder = RecentFolder(rootID: id, url: f.old, displayName: "old")
    try await recent.add(folder)
    #expect(try await recent.load() == [folder])
    #expect(try Data(contentsOf: recentPath) == futureRecent)
    #expect(try await RecentFolderStore(url: recentPath).load().isEmpty)
}

@Test(.timeLimit(.minutes(2))) func t216FixInterimEnvelopeAndOldRecoveryRemainVisible() async throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let first = AccessRootRecord(id: AccessRootID(), bookmark: Data("first".utf8), displayName: "first", creatingBuildSHA: "new", createdAt: .init(timeIntervalSinceReferenceDate: 0))
    let second = AccessRootRecord(id: AccessRootID(), bookmark: Data("second".utf8), displayName: "second", creatingBuildSHA: "old", createdAt: .init(timeIntervalSinceReferenceDate: 1))
    let rootPath = base.appendingPathComponent("roots.json")
    let rootObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "items": [rootObject]])
        .write(to: rootPath)
    try JSONEncoder().encode([second]).write(to: rootPath.appendingPathExtension("recovered"))
    #expect(try BookmarkStore(url: rootPath).load() == [first, second])

    let recentPath = base.appendingPathComponent("recent.json")
    let current = RecentFolder(rootID: first.id, url: base.appendingPathComponent("current"), displayName: "current", openedAt: .init(timeIntervalSinceReferenceDate: 0))
    let old = RecentFolder(rootID: second.id, url: base.appendingPathComponent("old"), displayName: "old", openedAt: .init(timeIntervalSinceReferenceDate: 1))
    let recentObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "items": [recentObject]])
        .write(to: recentPath)
    try JSONEncoder().encode([old]).write(to: recentPath.appendingPathExtension("recovered"))
    #expect(try await RecentFolderStore(url: recentPath).load() == [old, current])
}

@Test(.timeLimit(.minutes(2))) func t216FixLiteralOriginMainRecentBytesDecode() async throws {
    // Captured from origin/main's JSONEncoder for a fixed RecentFolder (same core model).
    let bytes = Data(#"[{"displayName":"legacy","openedAt":0,"url":"file:\/\/\/tmp\/legacy","rootID":{"rawValue":"11111111-2222-4333-8444-555555555555"}}]"#.utf8)
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("recent.json")
    try bytes.write(to: path)
    let store = RecentFolderStore(url: path)
    let items = try await store.load()
    let item = try #require(items.first)
    #expect(item.rootID.rawValue.uuidString == "11111111-2222-4333-8444-555555555555")
    #expect(item.url == URL(fileURLWithPath: "/tmp/legacy"))
    #expect(item.displayName == "legacy")
    #expect(item.openedAt == Date(timeIntervalSinceReferenceDate: 0))
}

@Test(.timeLimit(.minutes(2))) func t216FixUnsupportedArrayAndEmptyMarkerStayUntouched() async throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let rootPath = base.appendingPathComponent("roots.json")
    let futureArray = Data(#"[{"schemaVersion":99,"future":true}]"#.utf8)
    try futureArray.write(to: rootPath)
    let roots = BookmarkStore(url: rootPath)
    #expect(try roots.load().isEmpty)
    try roots.save([])
    #expect(try Data(contentsOf: rootPath) == futureArray)

    let recentPath = base.appendingPathComponent("recent.json")
    let empty = Data("[]".utf8)
    let marker = Data(#"{"schemaVersion":99}"#.utf8)
    try empty.write(to: recentPath)
    try marker.write(to: recentPath.appendingPathExtension("schema"))
    let recent = RecentFolderStore(url: recentPath)
    #expect(try await recent.load().isEmpty)
    try await recent.add(RecentFolder(rootID: AccessRootID(), url: base, displayName: "session"))
    #expect(try Data(contentsOf: recentPath) == empty)
    #expect(try Data(contentsOf: recentPath.appendingPathExtension("schema")) == marker)
}

@Test func t216FixInterimEnvelopeIgnoresDamagedRecovery() throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("roots.json")
    try Data(#"{"schemaVersion":1,"items":[]}"#.utf8).write(to: path)
    try Data("damaged".utf8).write(to: path.appendingPathExtension("recovered"))
    #expect(try BookmarkStore(url: path).load().isEmpty)
}

@Test func t216FixRecoveredRootReconnectionWinsOverInterimEnvelope() throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let id = AccessRootID()
    let old = AccessRootRecord(id: id, bookmark: Data("old".utf8), displayName: "old", creatingBuildSHA: "new", createdAt: .init(timeIntervalSinceReferenceDate: 0))
    let updated = AccessRootRecord(id: id, bookmark: Data("updated".utf8), displayName: "updated", creatingBuildSHA: "new", createdAt: .init(timeIntervalSinceReferenceDate: 0))
    let path = base.appendingPathComponent("roots.json")
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "items": [object]])
        .write(to: path)
    try JSONEncoder().encode([updated]).write(to: path.appendingPathExtension("recovered"))
    #expect(try BookmarkStore(url: path).load() == [updated])
}

@Test func t216FixFutureMarkerSurvivesLegacyNonemptyRewrite() throws {
    let base = fixDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("roots.json")
    let record = AccessRootRecord(id: AccessRootID(), bookmark: Data("legacy".utf8), displayName: "legacy", creatingBuildSHA: "old", createdAt: .init(timeIntervalSinceReferenceDate: 0))
    let oldBytes = try JSONEncoder().encode([record])
    let marker = Data(#"{"schemaVersion":99}"#.utf8)
    try oldBytes.write(to: path)
    try marker.write(to: path.appendingPathExtension("schema"))
    let store = BookmarkStore(url: path)
    #expect(try store.load() == [record])
    try store.save([])
    #expect(try Data(contentsOf: path) == oldBytes)
    #expect(try Data(contentsOf: path.appendingPathExtension("schema")) == marker)
}
