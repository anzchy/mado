import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private final class Issue358Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func add(_ value: String) { lock.withLock { recorded.append(value) } }
    func clear() { lock.withLock { recorded = [] } }
}

private final class Issue358Bookmarks: BookmarkCoding, @unchecked Sendable {
    let paths: [String: URL]
    let events: Issue358Events
    private let lock = NSLock()
    private var failing: Set<String> = []
    init(paths: [String: URL], events: Issue358Events) { self.paths = paths; self.events = events }
    func fail(_ tag: String) { lock.withLock { failing.insert(tag) } }
    func create(for url: URL) throws -> Data {
        events.add("create")
        return Data("new".utf8)
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let tag = String(decoding: data, as: UTF8.self)
        events.add("resolve:\(tag)")
        if lock.withLock({ failing.contains(tag) }) { throw FileAccessError.corruptStore }
        guard let url = paths[tag] else { throw FileAccessError.invalidFolder }
        return ResolvedBookmark(url: url, stale: false)
    }
}

private struct Issue358IdentityReader: FileIdentityResourceReading {
    let events: Issue358Events
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        events.add("read-identity")
        return FileResourceIdentity(volumeUUID: "v", fileIdentifier: "good")
    }
}

@Test(.timeLimit(.minutes(2)))
func issue358PersistedDestinationRejectsBeforeResolveAndBalancesEveryScope() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let old = base.appendingPathComponent("old", isDirectory: true)
    let chosen = base.appendingPathComponent("chosen", isDirectory: true)
    let other = base.appendingPathComponent("other", isDirectory: true)
    let denied = base.appendingPathComponent("denied", isDirectory: true)
    for url in [old, chosen, other, denied] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    defer { try? fm.removeItem(at: base) }

    let tags = ["A", "B", "C", "D", "E", "F", "G"]
    let ids = Dictionary(uniqueKeysWithValues: tags.map { ($0, AccessRootID()) })
    let paths = ["A": old, "B": other, "C": denied, "D": other,
                 "E": chosen, "F": chosen, "G": chosen, "new": chosen]
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    try store.save(tags.map { tag in
        AccessRootRecord(id: ids[tag]!, bookmark: Data(tag.utf8), displayName: tag,
                         creatingBuildSHA: "i358", createdAt: Date(timeIntervalSince1970: 0))
    })
    let events = Issue358Events()
    let bookmarks = Issue358Bookmarks(paths: paths, events: events)
    let scope = ReconnectScope()
    scope.beforeStart = { url in events.add("start:\(url.lastPathComponent)") }
    let access = try FileAccess(scope: scope, bookmarks: bookmarks, store: store, buildSHA: "i358",
        resourceReader: Issue358IdentityReader(events: events), requiresEmbeddedIdentity: false,
        bookmarkVolume: { data in
            let tag = String(decoding: data, as: UTF8.self)
            events.add("volume:\(tag)")
            let uuid: String? = tag == "F" ? "wrong" : tag == "G" ? "v" : nil
            return AccessProbeVolume(uuid: uuid, url: nil, name: nil)
        },
        resolvedVolumeUUID: { _ in events.add("resolved-volume"); return "v" },
        bookmarkLocation: { data in paths[String(decoding: data, as: UTF8.self)] },
        bookmarkIdentity: { data in
            let tag = String(decoding: data, as: UTF8.self)
            events.add("bookmark-identity:\(tag)")
            return tag == "E" ? FileResourceIdentity(volumeUUID: "v", fileIdentifier: "wrong")
                : tag == "F" || tag == "G" ? FileResourceIdentity(volumeUUID: "v", fileIdentifier: "good") : nil
        },
        mountedVolumesProvider: { [AccessProbeVolume(uuid: "wrong", url: nil, name: nil),
                                    AccessProbeVolume(uuid: "v", url: nil, name: nil)] })
    events.clear()
    bookmarks.fail("B")
    scope.rejected = denied
    let oldBefore = scope.counts(old)
    let result = try await access.rebind(ids["A"]!, folder: chosen,
        recentStore: RecentFolderStore(url: base.appendingPathComponent("recents.json")))
    #expect(result.rootID == ids["G"]!)
    #expect(scope.counts(old) == oldBefore) // Excluded A never starts a scope.
    #expect(scope.counts(denied) == [0, 0, 1]) // C's session start fails.
    #expect(scope.counts(other) == [1, 1, 0]) // D's destination mismatch continues.
    #expect(scope.balanced)
    #expect(scope.liveCount == 0)

    let beforeCreate = Array(events.values.prefix { $0 != "create" })
    let resolves = beforeCreate.filter { $0.hasPrefix("resolve:") }
    #expect(resolves == ["resolve:B", "resolve:C", "resolve:D", "resolve:E", "resolve:F", "resolve:G"])
    #expect(!beforeCreate.contains("resolve:A"))
    #expect(beforeCreate.contains("bookmark-identity:E"))
    #expect(beforeCreate.contains("bookmark-identity:F"))
    #expect(beforeCreate.contains("bookmark-identity:G"))
    #expect(beforeCreate.contains("resolved-volume"))
}
