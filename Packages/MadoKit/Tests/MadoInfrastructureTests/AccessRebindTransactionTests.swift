import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private struct RebindFixture {
    let base: URL
    let old: URL
    let chosen: URL
    let other: URL
    let roots: BookmarkStore
    let recentURL: URL
    let recents: RecentFolderStore
    let scope = ReconnectScope()
    let codec = ReconnectBookmarks()
    let access: FileAccess
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        old = base.appendingPathComponent("old", isDirectory: true)
        chosen = base.appendingPathComponent("new", isDirectory: true)
        other = base.appendingPathComponent("control", isDirectory: true)
        roots = BookmarkStore(url: base.appendingPathComponent("roots/state.json"))
        recentURL = base.appendingPathComponent("recents/state.json")
        recents = RecentFolderStore(url: recentURL)
        for url in [old, chosen, other, recentURL.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        access = try FileAccess(scope: scope, bookmarks: codec, store: roots, buildSHA: "WI2")
    }
    func remove() { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recentURL.deletingLastPathComponent().path); try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roots.url.deletingLastPathComponent().path); try? FileManager.default.removeItem(at: base) }
    func recent(_ id: AccessRootID, _ url: URL, _ label: String = "reference") -> RecentFolder {
        RecentFolder(rootID: id, url: URL(fileURLWithPath: url.path, isDirectory: true), displayName: label, openedAt: Date(timeIntervalSince1970: 1234))
    }
    func seed(_ values: [RecentFolder]) throws { try StoredSchema.writeItems(values, to: recentURL) }
    func bytes(_ url: URL) throws -> Data? { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231Fix1HistoricalRootLocationsRemapAfterInactiveFollow(merge: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let access = try FileAccess(scope: f.scope, bookmarks: SystemSecurityScope(), store: f.roots, buildSHA: "fix1-real")
    let a = try await access.grant(folder: f.old)
    let b = try await access.grant(folder: f.other)
    let destinationID = merge ? try await access.grant(folder: f.chosen) : nil
    for child in ["first", "middle", "last"] {
        try FileManager.default.createDirectory(at: f.old.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: true)
    }
    try f.seed([f.recent(a, f.old), f.recent(a, f.old.appendingPathComponent("first"), "first"), f.recent(b, f.other)])
    let heldB = try await access.acquire(.root(b, file: f.other))
    let renamed = f.base.appendingPathComponent("renamed", isDirectory: true)
    let latest = f.base.appendingPathComponent("latest", isDirectory: true)
    try FileManager.default.moveItem(at: f.old, to: renamed)
    #expect(try await access.probeRootURL(a).resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
    try FileManager.default.moveItem(at: renamed, to: latest)
    #expect(try await access.probeRootURL(a).resolvingSymlinksInPath().path == latest.resolvingSymlinksInPath().path)
    for child in ["first", "middle", "last"] {
        try FileManager.default.createDirectory(at: f.chosen.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: true)
    }
    let sourceRecent = [f.recent(a, f.old), f.recent(a, f.old.appendingPathComponent("first"), "first"),
        f.recent(b, f.other), f.recent(a, renamed.appendingPathComponent("middle"), "middle"),
        f.recent(a, latest.appendingPathComponent("last"), "last")]
    try f.seed(sourceRecent + (destinationID.map { [f.recent($0, f.chosen)] } ?? []))
    try FileManager.default.removeItem(at: latest)
    await #expect(throws: (any Error).self) { try await access.probeRootURL(a) }
    let before = try AccessStoreBytes(urls: [f.roots.url, f.recentURL])
    let result = try await access.rebind(a, folder: f.chosen, recentStore: f.recents)
    if let destinationID { #expect(result.rootID == destinationID) }
    else { #expect(result.rootID != a && result.rootID != b) }
    let recent = try await RecentFolderStore(url: f.recentURL).load()
    #expect(recent.allSatisfy { $0.rootID != a })
    #expect(recent.filter { $0.rootID == result.rootID && $0.url.path == f.chosen.path }.count == 1)
    for child in ["first", "middle", "last"] {
        #expect(recent.contains(f.recent(result.rootID, f.chosen.appendingPathComponent(child), child)))
    }
    #expect(recent.contains(f.recent(b, f.other)))
    #expect(try f.roots.load().allSatisfy { $0.id != a })
    try await access.undoRebind(result.undo)
    #expect(try AccessStoreBytes(urls: [f.roots.url, f.recentURL]) == before)
    #expect(await access.records().contains { $0.id == a })
    await access.release(heldB)
    #expect(f.scope.balanced)
}

private final class RebindTransactionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, URL?)] = []
    var events: [(String, URL?)] { lock.withLock { values.filter { $0.0.hasPrefix("AccessTransaction ") } } }
    func reset() { lock.withLock { values = [] } }
    var diagnostics: AccessDiagnostics { AccessDiagnostics { [self] text, path in lock.withLock { values.append((text, path)) } } }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true], ["schema", "write"])
func t231Fix1TransactionDiagnosticsMatchPersistenceAndRetry(undo: Bool, failure: String) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let trace = RebindTransactionTrace()
    let access = try FileAccess(scope: f.scope, bookmarks: f.codec, store: f.roots, buildSHA: "fix1-diagnostics", diagnostics: trace.diagnostics)
    let a = try await access.grant(folder: f.old)
    try f.seed([f.recent(a, f.old)])
    let original = try AccessStoreBytes(urls: [f.roots.url, f.recentURL])
    let rebound = undo ? try await access.rebind(a, folder: f.chosen, recentStore: f.recents) : nil
    trace.reset()
    let protectedURL = undo && failure == "schema" ? f.roots.url : f.recentURL
    let marker = protectedURL.appendingPathExtension("schema")
    let markerBefore = try f.bytes(marker)
    if failure == "schema" { try Data("{\"schemaVersion\":999}".utf8).write(to: marker) }
    else { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protectedURL.deletingLastPathComponent().path) }
    let before = try AccessStoreBytes(urls: [f.roots.url, f.recentURL])
    let records = await access.records()
    var caught: (any Error)?
    do {
        if let rebound { try await access.undoRebind(rebound.undo) }
        else { _ = try await access.rebind(a, folder: f.chosen, recentStore: f.recents) }
    } catch { caught = error }
    let error = try #require(caught)
    if failure == "schema" { #expect(error is StoredSchema.UnsupportedVersion) }
    #expect(try AccessStoreBytes(urls: [f.roots.url, f.recentURL]) == before)
    #expect(await access.records() == records)
    let operation = undo ? "undo" : "rebind"
    let stage = failure == "schema" ? (undo ? "validateRoots" : "validateRecents") : (undo ? "restore" : "writeRecents")
    let prefix = "AccessTransaction root=\(a.rawValue.uuidString) operation=\(operation)"
    let messages = trace.events.map(\.0)
    #expect(messages.first == "\(prefix) outcome=attempt stage=begin kind=none")
    #expect(messages.last == "\(prefix) outcome=error stage=\(stage) kind=\(AccessDiagnostics.errorKind(error))")
    #expect(messages.filter { $0.contains("outcome=attempt") }.count == 1)
    #expect(messages.filter { $0.contains("outcome=error") }.count == 1)
    #expect(messages.allSatisfy { !$0.contains("outcome=commit") && !$0.contains(f.base.path) })
    #expect(trace.events.allSatisfy { $0.1 == nil })
    #expect(messages.filter { $0.contains("outcome=rollback") }.count == (failure == "write" ? 1 : 0))
    if let markerBefore { try markerBefore.write(to: marker) }
    else if failure == "schema" { try FileManager.default.removeItem(at: marker) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedURL.deletingLastPathComponent().path)
    trace.reset()
    if let rebound {
        try await access.undoRebind(rebound.undo)
        #expect(try AccessStoreBytes(urls: [f.roots.url, f.recentURL]) == original)
    } else {
        let result = try await access.rebind(a, folder: f.chosen, recentStore: f.recents)
        #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen)])
        #expect(await access.records().allSatisfy { $0.id != a })
    }
    #expect(trace.events.map(\.0) == ["\(prefix) outcome=attempt stage=begin kind=none", "\(prefix) outcome=commit stage=publish kind=none"])
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231FreshRebindReplacesLostRecordAndUndoRestoresExactSnapshot(empty: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let c = try await f.access.grant(folder: f.other)
    if !empty { try f.seed([f.recent(a, f.old), f.recent(c, f.other)]) }
    let before = try f.bytes(f.roots.url), recentBefore = try f.bytes(f.recentURL)
    let records = await f.access.records()
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(result.rootID != a && result.rootID != c)
    #expect(result.rootURL == f.chosen)
    #expect(try f.roots.load().map(\.id) == [result.rootID, c])
    #expect(try f.roots.load().last == records.last)
    #expect(await f.access.rootURL(a) == nil)
    let reopened = try FileAccess(scope: f.scope, bookmarks: f.codec, store: f.roots, buildSHA: "reopen")
    #expect(await reopened.rootURL(result.rootID) == f.chosen)
    if !empty { #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen), f.recent(c, f.other)]) }
    try await f.access.undoRebind(result.undo)
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == recentBefore)
    #expect(await f.access.records() == records)
    await #expect(throws: (any Error).self) { try await f.access.undoRebind(result.undo) }
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231RebindMergeKeepsExistingIDAndUndoRestoresBothRecords(droppedResolvedRoot: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let b = try await f.access.grant(folder: f.chosen)
    let c = try await f.access.grant(folder: f.other)
    let records = await f.access.records()
    try f.seed([f.recent(a, f.old), f.recent(b, f.chosen), f.recent(c, f.other)])
    let before = try f.bytes(f.roots.url), recentBefore = try f.bytes(f.recentURL)
    if droppedResolvedRoot {
        f.codec.failingBookmarks = [try #require(records.first { $0.id == b }).bookmark]
        await #expect(throws: FileAccessError.needsReconnection(b)) { try await f.access.acquire(.root(b, file: f.chosen)) }
        #expect(await f.access.rootURL(b) == nil)
        f.codec.failingBookmarks = []
    }
    let alias = f.base.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.chosen)
    let result = try await f.access.rebind(a, folder: alias, recentStore: f.recents)
    #expect(result.rootID == b)
    #expect(try f.roots.load().map(\.id) == [b, c])
    #expect(try await f.recents.load() == [f.recent(b, f.chosen), f.recent(c, f.other)])
    try await f.access.undoRebind(result.undo)
    #expect(await f.access.records() == records)
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == recentBefore)
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)))
func t231RecentRemapRelativePathsPreservesMetadataAndUnrelatedOrder() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let c = try await f.access.grant(folder: f.other)
    let sub = f.chosen.appendingPathComponent("sub/deep")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let unrelated = f.recent(c, f.other), prefix = f.recent(a, f.base.appendingPathComponent("old-sibling"))
    try f.seed([f.recent(a, f.old), unrelated, f.recent(a, f.old.appendingPathComponent("sub"), "child"), prefix, f.recent(a, f.old.appendingPathComponent("sub/deep"), "deep")])
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen), unrelated, f.recent(result.rootID, f.chosen.appendingPathComponent("sub"), "child"), prefix, f.recent(result.rootID, sub, "deep")])
    #expect(try await RecentFolderStore(url: f.recentURL).load() == f.recents.load())
}

@Test(.timeLimit(.minutes(2)))
func t231RecentRemapChecksResolvedSymlinkContainment() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let real = f.chosen.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: f.chosen.appendingPathComponent("inside"), withDestinationURL: real)
    try FileManager.default.createSymbolicLink(at: f.chosen.appendingPathComponent("escape"), withDestinationURL: f.other)
    let escape = f.recent(a, f.old.appendingPathComponent("escape"))
    try f.seed([f.recent(a, f.old.appendingPathComponent("inside")), escape])
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(try await f.recents.load() == [f.recent(result.rootID, real), escape])
}

@Test(.timeLimit(.minutes(2)), arguments: [Int(EACCES), Int(EPERM), Int(EIO), 999])
func t231RecentRemapDropsOnlyConfirmedMissing(code: Int) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let uncertain = f.recent(a, f.old.appendingPathComponent("uncertain"))
    try f.seed([f.recent(a, f.old), f.recent(a, f.old.appendingPathComponent("missing")), uncertain])
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents, existenceProbe: { url in
        if url.lastPathComponent == "uncertain" { throw NSError(domain: code == 999 ? NSCocoaErrorDomain : NSPOSIXErrorDomain, code: code) }
        _ = try url.resourceValues(forKeys: [.isDirectoryKey])
    })
    #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen), f.recent(result.rootID, f.chosen.appendingPathComponent("uncertain"))])
}

@Test(.timeLimit(.minutes(2)), arguments: ["source", "missing", "file", "scope", "bookmark"])
func t231RebindGuardsRejectMissingSourceOrUnreadableSelectionWithoutMutation(kind: String) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    try f.seed([f.recent(a, f.old)])
    let before = try f.bytes(f.roots.url), recentBefore = try f.bytes(f.recentURL)
    let records = await f.access.records()
    let file = f.base.appendingPathComponent("file")
    try Data().write(to: file)
    if kind == "scope" { f.scope.rejected = f.chosen }
    if kind == "bookmark" { f.codec.creationFails = true }
    let selected = kind == "file" ? file : kind == "missing" ? f.base.appendingPathComponent("absent") : f.chosen
    await #expect(throws: (any Error).self) { try await f.access.rebind(kind == "source" ? AccessRootID() : a, folder: selected, recentStore: f.recents) }
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == recentBefore)
    #expect(await f.access.records() == records)
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: ["roots", "recents", "absent", "future", "corrupt"])
func t231PersistenceFailureRestoresBothStores(kind: String) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    if kind != "absent" { try f.seed([f.recent(a, f.old)]) }
    if kind == "future" { try Data("{\"schemaVersion\":999,\"items\":[]}".utf8).write(to: f.recentURL) }
    if kind == "corrupt" { try Data("damaged".utf8).write(to: f.recentURL); try Data("evidence".utf8).write(to: f.recentURL.appendingPathExtension("recovered")) }
    let before = try f.bytes(f.roots.url), recentBefore = try f.bytes(f.recentURL)
    let records = await f.access.records()
    if ["roots", "recents", "absent"].contains(kind) {
        let dir = kind == "roots" ? f.roots.url.deletingLastPathComponent() : f.recentURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }
    await #expect(throws: (any Error).self) { try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents) }
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == recentBefore)
    #expect(await f.access.records() == records)
    if kind == "corrupt" { #expect(try Data(contentsOf: f.recentURL.appendingPathExtension("recovered")) == Data("evidence".utf8)) }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231UndoPersistenceFailureKeepsReboundStateAndAllowsExactRetry(merge: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    if merge { _ = try await f.access.grant(folder: f.chosen) }
    try f.seed([f.recent(a, f.old)])
    let before = try f.bytes(f.roots.url), recentBefore = try f.bytes(f.recentURL)
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    let rebound = try f.bytes(f.roots.url), recentRebound = try f.bytes(f.recentURL)
    let records = await f.access.records()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.recentURL.deletingLastPathComponent().path)
    await #expect(throws: (any Error).self) { try await f.access.undoRebind(result.undo) }
    #expect(try f.bytes(f.roots.url) == rebound)
    #expect(try f.bytes(f.recentURL) == recentRebound)
    #expect(await f.access.records() == records)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.recentURL.deletingLastPathComponent().path)
    try await f.access.undoRebind(result.undo)
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == recentBefore)
}

@Test(.timeLimit(.minutes(2)))
func t231RebindHeldLeasesAndUndoNeverResurrectOldAuthority() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let stamp = try #require(await f.access.savedGrantSnapshot(a))
    let held = try await f.access.acquire(.root(a, file: f.old))
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(held.url == f.old && held.rootID == a)
    #expect(throws: (any Error).self) { try stamp.admitting { true } }
    let fresh = try await f.access.acquire(.root(result.rootID, file: f.chosen))
    let newStamp = try #require(await f.access.savedGrantSnapshot(result.rootID))
    try await f.access.undoRebind(result.undo)
    #expect(throws: (any Error).self) { try newStamp.admitting { true } }
    #expect(throws: (any Error).self) { try stamp.admitting { true } }
    for lease in [fresh, held, held, fresh] { await f.access.release(lease) }
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231CrossVolumeRebindAllowsDifferentStableVolumeIdentity(merge: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let volume: @Sendable (URL) -> String = { $0.lastPathComponent == "old" ? "V1" : "V2" }
    let access = try FileAccess(scope: f.scope, bookmarks: f.codec, store: f.roots, buildSHA: "volumes",
        bookmarkVolume: { data in
            let path = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).last!
            return AccessProbeVolume(uuid: volume(URL(fileURLWithPath: String(path))), url: nil, name: nil)
        }, resolvedVolumeUUID: { volume($0) })
    let a = try await access.grant(folder: f.old)
    let b = merge ? try await access.grant(folder: f.chosen) : nil
    try f.seed([f.recent(a, f.old)])
    let before = try f.bytes(f.roots.url), recentBefore = try f.bytes(f.recentURL)
    let result = try await access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(result.rootID != a)
    if let b { #expect(result.rootID == b) }
    #expect(await access.savedVolume(result.rootID)?.uuid == "V2")
    #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen)])
    try await access.undoRebind(result.undo)
    #expect(await access.savedVolume(a)?.uuid == "V1")
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == recentBefore)
}

@Test(.timeLimit(.minutes(2)))
func t231RebindLostAtRelaunchUsesBookmarkStoredRootPath() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let record = try #require(await f.access.records().first)
    f.codec.failingBookmarks = [record.bookmark]
    let relaunched = try FileAccess(scope: f.scope, bookmarks: f.codec, store: f.roots, buildSHA: "new",
        bookmarkLocation: { data in
            let path = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 1).last!
            return URL(fileURLWithPath: String(path), isDirectory: true)
        })
    #expect(await relaunched.rootURL(a) == nil)
    try FileManager.default.createDirectory(at: f.chosen.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try f.seed([f.recent(a, f.old.appendingPathComponent("sub"))])
    let result = try await relaunched.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen.appendingPathComponent("sub"))])
}

@Test(.timeLimit(.minutes(2)))
func t231RebindCancellationAndRetiredUndoLeaveCommittedBytes() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let before = try f.bytes(f.roots.url)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try f.bytes(f.roots.url) == before)
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    let rebound = try f.bytes(f.roots.url)
    await f.access.discardRebindUndo(result.undo)
    await #expect(throws: FileAccessError.invalidFolder) { try await f.access.undoRebind(result.undo) }
    #expect(try f.bytes(f.roots.url) == rebound)
}

@Test(.timeLimit(.minutes(2)))
func t231UndoSurvivesBenignBookmarkRefresh() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let before = try f.bytes(f.roots.url)
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    _ = try await f.access.grant(folder: f.chosen)
    try await f.access.undoRebind(result.undo)
    #expect(try f.bytes(f.roots.url) == before)
}

@Test(.timeLimit(.minutes(2)), arguments: ["grant", "rebind"])
func t231ExplicitTrashSelectionHasSessionAuthorityOnly(action: String) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let codec = SystemSecurityScope()
    let access = try FileAccess(scope: f.scope, bookmarks: codec, store: f.roots, buildSHA: "trash")
    let a = try await access.grant(folder: f.old)
    var trashed: NSURL?
    try FileManager.default.trashItem(at: f.chosen, resultingItemURL: &trashed)
    let selected = try #require(trashed as URL?)
    defer { try? FileManager.default.removeItem(at: selected) }
    let id: AccessRootID
    if action == "grant" { id = try await access.grant(folder: selected) }
    else { id = try await access.rebind(a, folder: selected, recentStore: f.recents).rootID }
    #expect(try await access.verifyExplicitSelection(id).path == selected.path)
    let lease = try await access.acquire(.root(id, file: selected))
    #expect(lease.rootID == id && lease.url.path == selected.path)
    await access.release(lease)
    let reopened = try FileAccess(scope: f.scope, bookmarks: codec, store: f.roots, buildSHA: "launch")
    #expect(await reopened.rootURL(id) == nil)
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await reopened.acquire(.root(id, file: selected)) }
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)))
func t231RebindRealDeletedBookmarkAfterRelaunchUsesStoredPath() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let codec = SystemSecurityScope()
    let first = try FileAccess(scope: f.scope, bookmarks: codec, store: f.roots, buildSHA: "real")
    let a = try await first.grant(folder: f.old)
    try f.seed([f.recent(a, f.old)])
    try FileManager.default.removeItem(at: f.old)
    let reopened = try FileAccess(scope: f.scope, bookmarks: codec, store: f.roots, buildSHA: "reopened")
    #expect(await reopened.rootURL(a) == nil)
    let result = try await reopened.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(try await f.recents.load() == [f.recent(result.rootID, f.chosen)])
}

@Test(.timeLimit(.minutes(2)))
func t231RebindRefusesUnknownOldRootLocation() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    f.codec.failingBookmarks = [try #require(await f.access.records().first).bookmark]
    let reopened = try FileAccess(scope: f.scope, bookmarks: f.codec, store: f.roots, buildSHA: "no-location")
    let before = try f.bytes(f.roots.url)
    await #expect(throws: FileAccessError.invalidFolder) { try await reopened.rebind(a, folder: f.chosen, recentStore: f.recents) }
    #expect(try f.bytes(f.roots.url) == before)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231RebindFailedWriteStillRetiresSavedGrantProof(undo: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    try f.seed([f.recent(a, f.old)])
    if undo {
        let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
        let proof = try #require(await f.access.savedGrantSnapshot(result.rootID))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.recentURL.deletingLastPathComponent().path)
        await #expect(throws: (any Error).self) { try await f.access.undoRebind(result.undo) }
        #expect(throws: (any Error).self) { try proof.admitting { true } }
    } else {
        let proof = try #require(await f.access.savedGrantSnapshot(a))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.recentURL.deletingLastPathComponent().path)
        await #expect(throws: (any Error).self) { try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents) }
        #expect(throws: (any Error).self) { try proof.admitting { true } }
    }
}

@Test(.timeLimit(.minutes(2)))
func t231ExplicitTrashSelectionRefusesReplacementAtSamePath() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    var trashed: NSURL?
    try FileManager.default.trashItem(at: f.chosen, resultingItemURL: &trashed)
    let selected = try #require(trashed as URL?)
    defer { try? FileManager.default.removeItem(at: selected) }
    let id = try await f.access.grant(folder: selected)
    try FileManager.default.moveItem(at: selected, to: f.base.appendingPathComponent("retained"))
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await f.access.acquire(.root(id, file: selected)) }
    #expect(await f.access.rootURL(id) == nil)
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)))
func t231MergeRecentCollisionAndUndoPreserveDestination() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let b = try await f.access.grant(folder: f.chosen)
    let c = try await f.access.grant(folder: f.other)
    let real = f.chosen.appendingPathComponent("real", isDirectory: true)
    let distinct = f.chosen.appendingPathComponent("distinct", isDirectory: true)
    for child in [real, distinct] { try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true) }
    let alias = f.chosen.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let destination = f.recent(b, real, "keep destination metadata")
    let otherDestination = f.recent(b, distinct, "distinct destination")
    let unrelated = f.recent(c, f.other)
    let before = [f.recent(a, f.old.appendingPathComponent("alias"), "old source metadata"), destination, otherDestination, unrelated]
    try f.seed(before)
    let bytes = try f.bytes(f.recentURL)
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(result.rootID == b)
    #expect(try await f.recents.load() == [destination, otherDestination, unrelated])
    try await f.access.undoRebind(result.undo)
    #expect(try await f.recents.load() == before)
    #expect(try f.bytes(f.recentURL) == bytes)
}

@Test(.timeLimit(.minutes(2)))
func t231UndoFirstStoreWriteFailureKeepsStateAndAllowsRetry() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let before = try f.bytes(f.roots.url)
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    let rebound = try f.bytes(f.roots.url), recentRebound = try f.bytes(f.recentURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.roots.url.deletingLastPathComponent().path)
    await #expect(throws: (any Error).self) { try await f.access.undoRebind(result.undo) }
    #expect(try f.bytes(f.roots.url) == rebound)
    #expect(try f.bytes(f.recentURL) == recentRebound)
    #expect(await f.access.records().map(\.id) == [result.rootID])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.roots.url.deletingLastPathComponent().path)
    try await f.access.undoRebind(result.undo)
    #expect(try f.bytes(f.roots.url) == before)
    #expect(try f.bytes(f.recentURL) == nil)
    #expect(try f.bytes(f.recentURL.appendingPathExtension("schema")) == nil)
}

@Test(.timeLimit(.minutes(2)))
func t231RebindKeepsLexicalSourceSuffixBeforeResolvingDestination() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let oldReal = f.old.appendingPathComponent("real", isDirectory: true)
    let oldAlias = f.old.appendingPathComponent("inside", isDirectory: true)
    let selectedInside = f.chosen.appendingPathComponent("inside", isDirectory: true)
    for directory in [oldReal, selectedInside, f.chosen.appendingPathComponent("real", isDirectory: true)] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(at: oldAlias, withDestinationURL: oldReal)
    try f.seed([f.recent(a, oldAlias)])
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    #expect(try await f.recents.load() == [f.recent(result.rootID, selectedInside)])
}

@Test(.timeLimit(.minutes(2)))
func t231RebindUndoRetiresProofForRootGrantedAfterSnapshot() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let a = try await f.access.grant(folder: f.old)
    let before = try f.bytes(f.roots.url)
    let result = try await f.access.rebind(a, folder: f.chosen, recentStore: f.recents)
    let c = try await f.access.grant(folder: f.other)
    let proof = try #require(await f.access.savedGrantSnapshot(c))
    let held = try await f.access.acquire(.root(c, file: f.other))
    #expect(try proof.admitting { true })
    try await f.access.undoRebind(result.undo)
    #expect(try f.bytes(f.roots.url) == before)
    #expect(await f.access.records().map(\.id) == [a])
    #expect(await f.access.rootURL(c) == nil)
    #expect(throws: (any Error).self) { try proof.admitting { true } }
    #expect(held.rootID == c && held.url == f.other)
    await f.access.release(held)
    await f.access.release(held)
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)))
func t231ExplicitTrashStillRefusesAutomaticRootProbe() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let access = try FileAccess(scope: f.scope, bookmarks: SystemSecurityScope(), store: f.roots, buildSHA: "automatic-trash")
    var trashed: NSURL?
    try FileManager.default.trashItem(at: f.chosen, resultingItemURL: &trashed)
    let selected = try #require(trashed as URL?)
    defer { try? FileManager.default.removeItem(at: selected) }
    let id = try await access.grant(folder: selected)
    #expect(try await access.verifyExplicitSelection(id).standardizedFileURL == selected.standardizedFileURL)
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.probeRootURL(id) }
    // Automatic rejection never consumes the user's still-valid explicit reader authority.
    let lease = try await access.acquire(.root(id, file: selected))
    #expect(lease.rootID == id)
    await access.release(lease)
}


/// Inject the additive field through persisted JSON so this specification compiles
/// against the legacy model before the implementation knows that field.
private func t231Fix2Reference(_ item: RecentFolder, recordedRoot: URL) throws -> RecentFolder {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    object["recordedRoot"] = recordedRoot.absoluteString
    return try JSONDecoder().decode(RecentFolder.self, from: JSONSerialization.data(withJSONObject: object))
}
private func t231Fix2RecordedRoot(_ item: RecentFolder) throws -> String? {
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    return object["recordedRoot"] as? String
}

@Test func t231Fix2LiteralLegacyAndAdditivePersistenceRoundTrip() throws {
    let legacy = Data(#"{"rootID":{"rawValue":"11111111-1111-1111-1111-111111111111"},"url":"file:///base/container/album/child/","displayName":"child","openedAt":0}"#.utf8)
    let decoded = try JSONDecoder().decode(RecentFolder.self, from: legacy)
    #expect(decoded.url.path == "/base/container/album/child")
    #expect(try t231Fix2RecordedRoot(decoded) == nil)
    #expect(try JSONDecoder().decode(RecentFolder.self, from: JSONEncoder().encode(decoded)) == decoded)
    let root = URL(fileURLWithPath: "/base/container/album", isDirectory: true)
    let recorded = try t231Fix2Reference(decoded, recordedRoot: root)
    #expect(try t231Fix2RecordedRoot(recorded) == root.absoluteString)
    #expect(try JSONDecoder().decode(RecentFolder.self, from: JSONEncoder().encode(recorded)) == recorded)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true], [false, true])
func t231Fix2PromotionUsesRecordedEpochAndSurvivesSecondRebind(merge: Bool, misleadingChild: Bool) async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let access = try FileAccess(scope: f.scope, bookmarks: SystemSecurityScope(), store: f.roots, buildSHA: "fix2-real")
    let container = f.base.appendingPathComponent("container", isDirectory: true)
    let original = container.appendingPathComponent("album", isDirectory: true)
    let child = original.appendingPathComponent("child", isDirectory: true)
    let staging = f.base.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let a = try await access.grant(folder: original)
    let b = try await access.grant(folder: f.other)
    let destinationID = merge ? try await access.grant(folder: f.chosen) : nil
    let recorded = try t231Fix2Reference(f.recent(a, child, "historical"), recordedRoot: original)
    try f.seed([recorded, f.recent(b, f.other)] + (destinationID.map { [f.recent($0, f.chosen, "destination")] } ?? []))
    let heldB = try await access.acquire(.root(b, file: f.other))
    try FileManager.default.moveItem(at: original, to: staging)
    #expect(try await access.probeRootURL(a).resolvingSymlinksInPath().path == staging.path)
    try FileManager.default.removeItem(at: container)
    try FileManager.default.moveItem(at: staging, to: container)
    #expect(try await access.probeRootURL(a).resolvingSymlinksInPath().path == container.path)
    try FileManager.default.createDirectory(at: f.chosen.appendingPathComponent("child"), withIntermediateDirectories: true)
    if misleadingChild {
        try FileManager.default.createDirectory(at: f.chosen.appendingPathComponent("album/child"), withIntermediateDirectories: true)
    }
    try FileManager.default.removeItem(at: container)
    await #expect(throws: (any Error).self) { try await access.probeRootURL(a) }
    let before = try AccessStoreBytes(urls: [f.roots.url, f.recentURL])
    let beforeRecords = await access.records()
    let first = try await access.rebind(a, folder: f.chosen, recentStore: f.recents)
    if let destinationID { #expect(first.rootID == destinationID) }
    else { #expect(first.rootID != a && first.rootID != b) }
    let recent = try await RecentFolderStore(url: f.recentURL).load()
    let mapped = recent.filter { $0.displayName == "historical" }
    #expect(mapped.count == 1)
    #expect(mapped.first?.url.path == f.chosen.appendingPathComponent("child").path)
    #expect(!mapped.contains { $0.url.path == f.chosen.appendingPathComponent("album/child").path })
    if let item = mapped.first {
        #expect(item.rootID == first.rootID && item.openedAt == recorded.openedAt)
        #expect(try t231Fix2RecordedRoot(item) == f.chosen.absoluteString)
    }
    #expect(recent.contains(f.recent(b, f.other)))
    #expect(recent.allSatisfy { $0.rootID != a })
    if let destinationID { #expect(recent.contains(f.recent(destinationID, f.chosen, "destination"))) }
    let secondRoot = f.base.appendingPathComponent("replacement2", isDirectory: true)
    try FileManager.default.createDirectory(at: secondRoot.appendingPathComponent("child"), withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: f.chosen)
    let afterFirst = try AccessStoreBytes(urls: [f.roots.url, f.recentURL])
    let firstRecords = await access.records()
    let second = try await access.rebind(first.rootID, folder: secondRoot, recentStore: f.recents)
    let twice = try await RecentFolderStore(url: f.recentURL).load().filter { $0.displayName == "historical" }
    #expect(twice.count == 1)
    #expect(twice.first?.url.path == secondRoot.appendingPathComponent("child").path)
    if let item = twice.first { #expect(try t231Fix2RecordedRoot(item) == secondRoot.absoluteString) }
    try await access.undoRebind(second.undo)
    #expect(try AccessStoreBytes(urls: [f.roots.url, f.recentURL]) == afterFirst)
    #expect(await access.records() == firstRecords)
    try await access.undoRebind(first.undo)
    #expect(try AccessStoreBytes(urls: [f.roots.url, f.recentURL]) == before)
    #expect(await access.records() == beforeRecords)
    await access.release(heldB)
    #expect(f.scope.balanced)
}

@Test(.timeLimit(.minutes(2)))
func t231Fix2NewerRecordedAndLegacyOverlapKeepTheirOwnMeaning() async throws {
    let f = try RebindFixture(); defer { f.remove() }
    let access = try FileAccess(scope: f.scope, bookmarks: SystemSecurityScope(), store: f.roots, buildSHA: "fix2-inverse")
    let container = f.base.appendingPathComponent("container", isDirectory: true)
    let original = container.appendingPathComponent("album", isDirectory: true)
    let child = original.appendingPathComponent("child", isDirectory: true)
    let staging = f.base.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let a = try await access.grant(folder: original)
    try FileManager.default.moveItem(at: original, to: staging)
    _ = try await access.probeRootURL(a)
    try FileManager.default.removeItem(at: container)
    try FileManager.default.moveItem(at: staging, to: container)
    _ = try await access.probeRootURL(a)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let newer = try t231Fix2Reference(f.recent(a, child, "newer"), recordedRoot: container)
    // Decode an actual old-format representation, with no recordedRoot field.
    let legacy = try JSONDecoder().decode(RecentFolder.self, from: JSONEncoder().encode(f.recent(a, child, "legacy")))
    try f.seed([newer, legacy])
    for suffix in ["child", "album/child"] {
        try FileManager.default.createDirectory(at: f.chosen.appendingPathComponent(suffix), withIntermediateDirectories: true)
    }
    try FileManager.default.removeItem(at: container)
    let result = try await access.rebind(a, folder: f.chosen, recentStore: f.recents)
    let recent = try await RecentFolderStore(url: f.recentURL).load()
    // Equal destination paths coalesce; assert each provenance behavior separately
    // using the production remapper and persisted reload below.
    #expect(recent.first?.url.path == f.chosen.appendingPathComponent("album/child").path)
    #expect(recent.first?.rootID == result.rootID)
    if let item = recent.first { #expect(try t231Fix2RecordedRoot(item) == f.chosen.absoluteString) }
    let legacyMapped = AccessRecentRemap.remap([legacy], sourceID: a, oldRoots: [container, staging, original],
        destinationID: result.rootID, newRoot: f.chosen, probe: { _ = try $0.resourceValues(forKeys: [.isDirectoryKey]) })
    try f.seed(legacyMapped)
    let persistedLegacy = try #require(try await RecentFolderStore(url: f.recentURL).load().first)
    #expect(persistedLegacy.url.path == f.chosen.appendingPathComponent("album/child").path)
    #expect(try t231Fix2RecordedRoot(persistedLegacy) == nil)
}

@Test func t231Fix2InvalidRecordedRootDoesNotFallBackOrEscape() throws {
    let f = try RebindFixture(); defer { f.remove() }
    let source = AccessRootID(), destination = AccessRootID()
    let original = try t231Fix2Reference(f.recent(source, f.old.appendingPathComponent("child")), recordedRoot: f.other)
    try FileManager.default.createDirectory(at: f.chosen.appendingPathComponent("child"), withIntermediateDirectories: true)
    let retained = AccessRecentRemap.remap([original], sourceID: source, oldRoots: [f.old],
        destinationID: destination, newRoot: f.chosen, probe: { _ = try $0.resourceValues(forKeys: [.isDirectoryKey]) })
    #expect(retained == [original])
    try FileManager.default.createSymbolicLink(at: f.chosen.appendingPathComponent("escape"), withDestinationURL: f.other)
    let escaping = try t231Fix2Reference(f.recent(source, f.old.appendingPathComponent("escape")), recordedRoot: f.old)
    let checked = AccessRecentRemap.remap([escaping], sourceID: source, oldRoots: [f.old],
        destinationID: destination, newRoot: f.chosen, probe: { _ = try $0.resourceValues(forKeys: [.isDirectoryKey]) })
    #expect(checked == [escaping])
}
