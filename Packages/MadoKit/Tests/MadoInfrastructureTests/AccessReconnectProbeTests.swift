import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private enum ProbePresentation: Equatable {
    case browse(AccessRootID, URL)
    case reconnect(AccessRootID, URL, String)
    case error
}

@MainActor private final class ProbeHost: AccessRecoveryHost {
    var history: [ProbePresentation] = []
    var error: (any Error)?
    func browseRecoveredFolder(_ url: URL, rootID: AccessRootID) { history.append(.browse(rootID, url)) }
    func requestFolderReconnection(rootID: AccessRootID, lastKnownFolder: URL, displayName: String) {
        history.append(.reconnect(rootID, lastKnownFolder, displayName))
    }
    func showAccessRecoveryError(_ error: any Error) { self.error = error; history.append(.error) }
}

private func probeResult(_ access: FileAccess, _ id: AccessRootID) async -> Result<URL?, any Error> {
    do { return .success(try await access.probeRootURL(id)) }
    catch { return .failure(error) }
}

@MainActor @Test(.timeLimit(.minutes(2))) func p201Fix1FirstRecentAfterLaunchResolutionLossReconnects() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = FakeBookmarks(); let scope = ReconnectScope()
    let original = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await original.grant(folder: f.old)
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    #expect(await access.launchOutcomes()[id] == "resolved")
    let records = await access.records(); let bytes = try Data(contentsOf: f.store.url)
    let counts = scope.counts(f.old); let creations = codec.count
    codec.fails = true
    // Query remains a published-cache read even though a real probe must now fail.
    #expect(await access.rootURL(id) == f.old)
    #expect(await access.rootURL(id) == f.old)
    #expect(await access.rootURL(AccessRootID()) == nil)
    #expect(scope.counts(f.old) == counts && codec.count == creations)
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    let result = await probeResult(access, id)
    if case .failure(let error) = result { #expect(error as? FileAccessError == .needsReconnection(id)) }
    else { Issue.record("Live resolution loss must fail the probe") }
    let recent = RecentFolder(rootID: id, url: f.old, displayName: "Holiday")
    let host = ProbeHost()
    #expect(AccessRecovery.openRecent(recent, currentURL: result, host: host) ==
            .reconnect(rootID: id, lastKnownFolder: f.old, displayName: "Holiday"))
    #expect(host.history == [.reconnect(id, f.old, "Holiday")])
    #expect(host.error == nil)
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(scope.counts(f.old) == counts && codec.count == creations)
    #expect(scope.balanced)
}

@MainActor @Test(.timeLimit(.minutes(2))) func p201Fix1RepeatedProbesReleaseBeforeBrowsing() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = FakeBookmarks(); let scope = ReconnectScope()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    let recent = RecentFolder(rootID: id, url: f.chosen, displayName: "obsolete")
    let host = ProbeHost()
    let first = try await access.probeRootURL(id)
    #expect(first == f.old)
    #expect(scope.counts(f.old) == [2, 2, 0] && scope.liveCount == 0)
    #expect(AccessRecovery.openRecent(recent, currentURL: .success(first), host: host) == .browse(f.old))
    let second = try await access.probeRootURL(id)
    #expect(second == f.old)
    #expect(scope.counts(f.old) == [3, 3, 0] && scope.liveCount == 0)
    #expect(AccessRecovery.openRecent(recent, currentURL: .success(second), host: host) == .browse(f.old))
    #expect(host.history == [.browse(id, f.old), .browse(id, f.old)])
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2))) func p201Fix1HeldLeaseSurvivesSuccessfulAndFailedProbe() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = FakeBookmarks(); let scope = ReconnectScope()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let held = try await access.acquire(.root(id, file: f.old))
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    #expect(try await access.probeRootURL(id) == f.old)
    #expect(scope.counts(f.old) == [2, 1, 0] && scope.liveCount == 1)
    codec.fails = true
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.probeRootURL(id) }
    #expect(scope.counts(f.old) == [2, 1, 0] && scope.liveCount == 1)
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    await access.release(held)
    #expect(scope.counts(f.old) == [2, 2, 0] && scope.liveCount == 0)
    await access.release(held)
    #expect(scope.counts(f.old) == [2, 2, 0] && scope.balanced)
}

@MainActor @Test(.timeLimit(.minutes(2))) func p201Fix1MoveAfterLaunchProbesLiveLocationAndKeepsOldLease() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = FakeBookmarks(); let scope = ReconnectScope()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let held = try await access.acquire(.root(id, file: f.old))
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    codec.relocated = f.chosen
    #expect(await access.rootURL(id) == f.old)
    let current = try await access.probeRootURL(id)
    #expect(current == f.chosen)
    #expect(await access.rootURL(id) == f.chosen)
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [1, 1, 0] && scope.liveCount == 1)
    let host = ProbeHost()
    let recent = RecentFolder(rootID: id, url: f.old, displayName: "Holiday")
    #expect(AccessRecovery.openRecent(recent, currentURL: .success(current), host: host) == .browse(f.chosen))
    #expect(host.history == [.browse(id, f.chosen)])
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    await access.release(held)
    #expect(scope.counts(f.old) == [2, 2, 0] && scope.balanced)
}

@MainActor @Test(.timeLimit(.minutes(2)), arguments: [false, true])
func p201Fix1MissingAndUnresolvedRootsNeverGrant(unresolved: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = FakeBookmarks(); let scope = ReconnectScope()
    let original = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let savedID = try await original.grant(folder: f.old)
    let id = unresolved ? savedID : AccessRootID()
    codec.fails = unresolved
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    let counts = scope.counts(f.old); let creations = codec.count
    let result = await probeResult(access, id)
    if case .failure(let error) = result { #expect(error as? FileAccessError == .needsReconnection(id)) }
    else { Issue.record("Absent or unresolved roots must require reconnection") }
    let recent = RecentFolder(rootID: id, url: f.old, displayName: "Holiday")
    let host = ProbeHost()
    #expect(AccessRecovery.openRecent(recent, currentURL: result, host: host) ==
            .reconnect(rootID: id, lastKnownFolder: f.old, displayName: "Holiday"))
    #expect(host.history == [.reconnect(id, f.old, "Holiday")])
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(scope.counts(f.old) == counts && codec.count == creations && scope.balanced)
}

@MainActor @Test(.timeLimit(.minutes(2))) func p201Fix1DeniedStartDoesNotStopOrFabricateReconnection() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = FakeBookmarks(); let scope = ReconnectScope()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    scope.rejected = f.old
    let result = await probeResult(access, id)
    if case .failure(let error) = result { #expect(error as? FileAccessError == .startFailed) }
    else { Issue.record("Denied scope must fail the probe") }
    let host = ProbeHost()
    let recent = RecentFolder(rootID: id, url: f.old, displayName: "Holiday")
    #expect(AccessRecovery.openRecent(recent, currentURL: result, host: host) == .error)
    #expect(host.history == [.error] && host.error as? FileAccessError == .startFailed)
    #expect(scope.counts(f.old) == [1, 1, 1] && scope.balanced)
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
}

private final class ProbeSequencedBookmarks: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var successesRemaining: Int?
    func failAfterNextResolution() { lock.withLock { successesRemaining = 1 } }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        try lock.withLock {
            if let left = successesRemaining {
                guard left > 0 else { throw FileAccessError.corruptStore }
                successesRemaining = left - 1
            }
            return ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func p201Fix1LossDuringAcquisitionDoesNotReturnEarlierResolution() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let codec = ProbeSequencedBookmarks(); let scope = ReconnectScope()
    let original = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await original.grant(folder: f.old)
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    let bytes = try Data(contentsOf: f.store.url); let records = await access.records()
    codec.failAfterNextResolution()
    let result = await probeResult(access, id)
    if case .failure(let error) = result { #expect(error as? FileAccessError == .needsReconnection(id)) }
    else { Issue.record("An earlier resolution cannot replace a successful lease") }
    let host = ProbeHost()
    let recent = RecentFolder(rootID: id, url: f.old, displayName: "Holiday")
    #expect(AccessRecovery.openRecent(recent, currentURL: result, host: host) ==
            .reconnect(rootID: id, lastKnownFolder: f.old, displayName: "Holiday"))
    #expect(host.history == [.reconnect(id, f.old, "Holiday")])
    #expect(scope.counts(f.old) == [1, 1, 0] && scope.balanced)
    #expect(await access.records() == records)
    #expect(try Data(contentsOf: f.store.url) == bytes)
}
