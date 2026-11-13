import Foundation
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

private func schemaTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test func t216AccessRootsVersionAndFuturePreservation() throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let path = base.appendingPathComponent("roots.json")
    let store = BookmarkStore(url: path)
    try store.save([])
    let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [Any])
    #expect(current.isEmpty)
    let marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathExtension("schema"))) as? [String: Any])
    #expect(marker["schemaVersion"] as? Int == 1)
    #expect(try store.load().isEmpty)
    try Data("[]".utf8).write(to: path)
    #expect(try store.load().isEmpty)
    let future = Data(#"{"schemaVersion":99,"items":[{"future":true}]}"#.utf8)
    try future.write(to: path)
    #expect(try store.load().isEmpty)
    try store.save([])
    #expect(try Data(contentsOf: path) == future)
}

@Test(.timeLimit(.minutes(2))) func t216RecentFoldersVersionAndFuturePreservation() async throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let path = base.appendingPathComponent("recent.json")
    let store = RecentFolderStore(url: path)
    let folder = RecentFolder(rootID: AccessRootID(), url: base, displayName: "photos")
    try await store.add(folder)
    let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]])
    #expect(current.first?["schemaVersion"] as? Int == 1)
    #expect(try await store.load() == [folder])
    let legacy = try JSONEncoder().encode([folder])
    try legacy.write(to: path)
    #expect(try await store.load() == [folder])
    let future = Data(#"{"schemaVersion":99,"items":[{"future":true}]}"#.utf8)
    try future.write(to: path)
    #expect(try await store.load().isEmpty)
    try await store.add(folder)
    #expect(try Data(contentsOf: path) == future)
}

@Test(.timeLimit(.minutes(2))) func t216PersonalImagesVersionAndFuturePreservation() async throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let path = base.appendingPathComponent("personal.json")
    let store = PersonalImageStore(url: path)
    let root = ItemIdentityRoot(id: AccessRootID(), url: base)
    let ref = try #require(PersonalImageRef(fileURL: base.appendingPathComponent("a.jpg"), root: root, fileNumber: 1))
    _ = try await store.toggleFavorite(ref)
    let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(current["version"] as? Int == 1)
    #expect(try await store.favorites() == [ref])
    var legacy = current; legacy.removeValue(forKey: "version")
    try JSONSerialization.data(withJSONObject: legacy).write(to: path)
    #expect(try await store.favorites() == [ref])
    let future = Data(#"{"version":99,"favorites":[],"recents":[]}"#.utf8)
    try future.write(to: path)
    #expect(try await store.favorites().isEmpty)
    await #expect(throws: (any Error).self) { _ = try await store.toggleFavorite(ref) }
    #expect(try Data(contentsOf: path) == future)
}

@Test(.timeLimit(.minutes(2))) @MainActor func t216DisplayPreferencesVersionAndFuturePreservation() throws {
    let suite = "mado.schema.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "displayPreferences.v1"
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    store.value = DisplayPreferences(appearance: .dark)
    let stored = try #require(defaults.data(forKey: key))
    let current = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(current["schemaVersion"] as? Int == 1)
    #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value.appearance == .dark)
    defaults.set(Data(#"{"appearance":"light","alwaysShowTools":false,"filmstripExpanded":false}"#.utf8), forKey: key)
    #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value.appearance == .light)
    let future = Data(#"{"schemaVersion":99,"value":{"appearance":"dark"}}"#.utf8)
    defaults.set(future, forKey: key)
    let futureStore = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(futureStore.value == DisplayPreferences())
    futureStore.value = DisplayPreferences(appearance: .light)
    #expect(defaults.data(forKey: key) == future)
}

@Test(.timeLimit(.minutes(2))) @MainActor func t216ExplicitOlderVersionsArePreserved() async throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let oldItems = Data(#"{"schemaVersion":0,"items":[{"old":true}]}"#.utf8)
    let rootPath = base.appendingPathComponent("roots.json")
    try oldItems.write(to: rootPath)
    let roots = BookmarkStore(url: rootPath)
    #expect(try roots.load().isEmpty)
    try roots.save([])
    #expect(try Data(contentsOf: rootPath) == oldItems)

    let recentPath = base.appendingPathComponent("recent.json")
    try oldItems.write(to: recentPath)
    let recent = RecentFolderStore(url: recentPath)
    #expect(try await recent.load().isEmpty)
    let folder = RecentFolder(rootID: AccessRootID(), url: base, displayName: "old")
    try await recent.add(folder)
    #expect(try Data(contentsOf: recentPath) == oldItems)

    let personalPath = base.appendingPathComponent("personal.json")
    let oldPersonal = Data(#"{"version":0,"favorites":[],"recents":[]}"#.utf8)
    try oldPersonal.write(to: personalPath)
    let personal = PersonalImageStore(url: personalPath)
    #expect(try await personal.favorites().isEmpty)
    let root = ItemIdentityRoot(id: AccessRootID(), url: base)
    let ref = try #require(PersonalImageRef(fileURL: base.appendingPathComponent("a.jpg"), root: root, fileNumber: 1))
    await #expect(throws: (any Error).self) { _ = try await personal.toggleFavorite(ref) }
    #expect(try Data(contentsOf: personalPath) == oldPersonal)
    #expect(!FileManager.default.fileExists(atPath: personalPath.appendingPathExtension("recovered").path))

    let suite = "mado.schema.old.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldPreference = Data(#"{"schemaVersion":0,"value":{"appearance":"light"}}"#.utf8)
    defaults.set(oldPreference, forKey: "displayPreferences.v1")
    let preferences = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(preferences.value == DisplayPreferences())
    preferences.value = DisplayPreferences(appearance: .dark)
    #expect(defaults.data(forKey: "displayPreferences.v1") == oldPreference)
}

@Test func t216AccessRootsLegacyRecordKeepsEveryField() throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("roots.json")
    let legacy = Data(#"[{"id":{"rawValue":"11111111-2222-4333-8444-555555555555"},"bookmark":"L3RtcC9sZWdhY3k=","displayName":"legacy","creatingBuildSHA":"P0","createdAt":0}]"#.utf8)
    try legacy.write(to: path)
    let store = BookmarkStore(url: path)
    let record = try #require(store.load().first)
    #expect(record.id.rawValue.uuidString == "11111111-2222-4333-8444-555555555555")
    #expect(record.bookmark == Data("/tmp/legacy".utf8))
    #expect(record.displayName == "legacy")
    #expect(record.creatingBuildSHA == "P0")
    #expect(record.createdAt == Date(timeIntervalSinceReferenceDate: 0))
    try store.save([record])
    #expect(try store.load() == [record])
}

@Test(.timeLimit(.minutes(2))) func t216FutureRecentRecoveryStaysByteIdentical() async throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("recent.json")
    let recovery = path.appendingPathExtension("recovered")
    let future = Data(#"{"schemaVersion":99,"items":[{"future":true}]}"#.utf8)
    try Data("damaged".utf8).write(to: path)
    try future.write(to: recovery)
    let store = RecentFolderStore(url: path)
    #expect(try await store.load().isEmpty)
    #expect(await store.storeCorrupt)
    let folder = RecentFolder(rootID: AccessRootID(), url: base, displayName: "photos")
    try await store.add(folder)
    #expect(try Data(contentsOf: recovery) == future)
}

@Test(.timeLimit(.minutes(2))) func t216FuturePersonalRecoveryStaysByteIdentical() async throws {
    let base = schemaTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("personal.json")
    let recovery = path.appendingPathExtension("recovered")
    let future = Data(#"{"version":99,"favorites":[],"recents":[]}"#.utf8)
    try Data("damaged".utf8).write(to: path)
    try future.write(to: recovery)
    let store = PersonalImageStore(url: path)
    #expect(try await store.favorites().isEmpty)
    #expect(await store.storeCorrupt)
    let root = ItemIdentityRoot(id: AccessRootID(), url: base)
    let ref = try #require(PersonalImageRef(fileURL: base.appendingPathComponent("a.jpg"), root: root, fileNumber: 1))
    await #expect(throws: (any Error).self) { _ = try await store.toggleFavorite(ref) }
    #expect(try Data(contentsOf: recovery) == future)
}

@Test(.timeLimit(.minutes(2))) @MainActor func t216FuturePreferencesRemainUsableInMemory() throws {
    let suite = "mado.schema.future.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "displayPreferences.v1"
    let future = Data(#"{"schemaVersion":99,"value":{"appearance":"light"}}"#.utf8)
    defaults.set(future, forKey: key)
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    store.value = DisplayPreferences(appearance: .dark)
    #expect(store.value.appearance == .dark)
    #expect(defaults.data(forKey: key) == future)
}
