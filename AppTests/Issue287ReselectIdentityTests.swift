import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

/// #287: with no in-window folder reference, reselect proves the folder against the identity
/// embedded in the saved bookmark. Real system bookmarks, so that identity is parsed, not faked.
@MainActor private struct ReselectIdentityFixture {
    let base: URL
    let a: URL
    let b: URL
    let rootA: AccessRootID
    let services: AccessServices
    let lost: AccessRootSnapshot?
    init() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let a = base.appendingPathComponent("RootA", isDirectory: true), b = base.appendingPathComponent("RootB", isDirectory: true)
        for folder in [a, b] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        try fm.copyItem(at: fixture, to: a.appendingPathComponent("root.png"))
        try fm.copyItem(at: fixture, to: b.appendingPathComponent("other.png"))
        let scope = SystemSecurityScope()
        let files = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue287-reselect")
        let services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()),
            selectionScope: scope)
        let rootA = try await services.grant(a)
        try await waitUntil { services.monitor.state.snapshot(for: rootA)?.availability == .readable }
        services.monitor.state.reportRootFailure(rootA, cause: .accessExpired, from: services.monitor.state.stamp(for: rootA))
        self.base = base; self.a = a; self.b = b; self.rootA = rootA; self.services = services
        lost = services.monitor.state.snapshot(for: rootA)
    }
    /// The fallback is only exercised when the saved bookmark carries an identity it can parse.
    func embeddedIdentity() async throws -> FileResourceIdentity {
        let saved = try #require(await services.files.savedGrantSnapshot(rootA))
        return try #require(AccessProbeFactGatherer.bookmarkIdentity(in: saved.record.bookmark))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

/// A resolved bookmark spells the temporary directory `/private/var`; `resolvingSymlinksInPath` spells it `/var`.
private func canonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func i287SameIdentityWithoutReferenceRestoresOriginalRoot(_ moved: Bool) async throws {
    let f = try await ReselectIdentityFixture(); defer { f.remove() }
    #expect(f.lost?.availability == .lost(.accessExpired))
    let identity = try await f.embeddedIdentity()
    var selected = f.a
    if moved {
        // A new spelling for the same directory: only the identity, not the path, can match it.
        selected = f.base.appendingPathComponent("RootAMoved", isDirectory: true)
        try FileManager.default.moveItem(at: f.a, to: selected)
    }
    #expect(try URLIdentityResourceReader().identity(for: selected) == identity)

    let result = try await f.services.reselect(f.rootA, folder: selected, reference: nil)

    #expect(result.rootID == f.rootA && result.restored && result.url == selected)
    #expect(await f.services.files.records().map(\.id) == [f.rootA])
    #expect(await f.services.files.rootURL(f.rootA).map(canonicalPath) == canonicalPath(selected))
    try await waitUntil { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable }
    #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable)
    #expect(try await f.services.recent.load().map(\.rootID) == [f.rootA])
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["other", "replacement"])
func i287DifferentIdentityWithoutReferenceOpensNewRootAndLeavesOriginalLost(_ kind: String) async throws {
    let f = try await ReselectIdentityFixture(); defer { f.remove() }
    #expect(f.lost?.availability == .lost(.accessExpired))
    let identity = try await f.embeddedIdentity()
    let original = try #require(await f.services.files.records().first { $0.id == f.rootA })
    var selected = f.b
    if kind == "replacement" {
        // A new directory at the original spelling is a different folder.
        try FileManager.default.moveItem(at: f.a, to: f.base.appendingPathComponent("OriginalElsewhere", isDirectory: true))
        try FileManager.default.createDirectory(at: f.a, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.b.appendingPathComponent("other.png"), to: f.a.appendingPathComponent("new.png"))
        selected = f.a
    }
    #expect(try URLIdentityResourceReader().identity(for: selected) != identity)

    let result = try await f.services.reselect(f.rootA, folder: selected, reference: nil)

    #expect(result.rootID != f.rootA && !result.restored && result.url == selected)
    let records = await f.services.files.records()
    #expect(records.count == 2 && records.contains { $0.id == result.rootID })
    #expect(records.first { $0.id == f.rootA } == original)
    #expect(await f.services.files.rootURL(result.rootID).map(canonicalPath) == canonicalPath(selected))
    #expect(f.services.monitor.state.snapshot(for: f.rootA) == f.lost)
    #expect(try await f.services.recent.load().first?.rootID == result.rootID)
}
