import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func p201LeaseRebindReconnectKeepsEachTokensOriginalSession() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let old = try await access.acquire(.root(id, file: f.old))
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(try await access.reconnect(id, folder: f.chosen) == f.chosen)
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [1, 1, 0])
    let new = try await access.acquire(.root(id, file: f.chosen))
    #expect(old.url == f.old && new.url == f.chosen)
    #expect(old.rootID == id && new.rootID == id)
    #expect(scope.counts(f.chosen) == [2, 1, 0])
    await #expect(throws: FileAccessError.outsideRoot) { try await access.acquire(.root(id, file: f.old)) }
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [2, 1, 0])
    await access.release(old)
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.counts(f.chosen) == [2, 1, 0])
    await access.release(new)
    #expect(scope.counts(f.chosen) == [2, 2, 0])
    #expect(Array(scope.stops.suffix(2)) == [f.old, f.chosen])
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2))) func p201LeaseRebindStaleRelocationSeparatesLiveSessionsAndPersists() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let old = try await access.acquire(.root(id, file: f.old))
    codec.relocated = f.chosen; codec.stale = true
    let new = try await access.acquire(.root(id, file: f.chosen))
    #expect(old.url == f.old && new.url == f.chosen)
    #expect(old.rootID == id && new.rootID == id)
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [1, 0, 0])
    #expect(try f.store.load().first?.bookmark == Data(f.chosen.path.utf8))
    #expect(codec.count == 2)
    await #expect(throws: FileAccessError.outsideRoot) { try await access.acquire(.root(id, file: f.old)) }
    #expect(codec.count == 2)
    await access.release(new)
    #expect(scope.counts(f.chosen) == [1, 1, 0])
    #expect(scope.counts(f.old) == [2, 1, 0])
    await access.release(old)
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(Array(scope.stops.suffix(2)) == [f.chosen, f.old])
    codec.stale = false
    let relaunched = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
    let restored = try await relaunched.acquire(.root(id, file: f.chosen))
    #expect(restored.url == f.chosen && restored.rootID == id)
    await relaunched.release(restored)
    #expect(scope.counts(f.chosen) == [2, 2, 0])
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2, 3])
func p201LeaseRebindReleasePermutationsAndDuplicatesConserveScopes(scenario: Int) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let a1 = try await access.acquire(.root(id, file: f.old))
    let a2 = try await access.acquire(.root(id, file: f.old.appendingPathComponent("a.png")))
    _ = try await access.reconnect(id, folder: f.chosen)
    let b1 = try await access.acquire(.root(id, file: f.chosen))
    let b2 = try await access.acquire(.root(id, file: f.chosen.appendingPathComponent("a.png")))
    let leases = [a1, a2, b1, b2]
    #expect(leases.map(\.url) == [f.old, f.old, f.chosen, f.chosen])
    #expect(Set(leases.map(\.token)).count == 4)
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [2, 1, 0])
    let order: [Int]
    let oldStops: [Int]
    let newStops: [Int]
    switch scenario {
    case 0: order = [0, 1, 2, 3]; oldStops = [1, 2, 2, 2]; newStops = [1, 1, 1, 2]
    case 1: order = [2, 0, 3, 1]; oldStops = [1, 1, 1, 2]; newStops = [1, 1, 2, 2]
    case 2: order = [1, 3, 0, 2]; oldStops = [1, 1, 2, 2]; newStops = [1, 1, 1, 2]
    default: order = [3, 2, 1, 0]; oldStops = [1, 1, 1, 2]; newStops = [1, 2, 2, 2]
    }
    for (step, index) in order.enumerated() {
        await access.release(leases[index])
        #expect(scope.counts(f.old) == [2, oldStops[step], 0])
        #expect(scope.counts(f.chosen) == [2, newStops[step], 0])
        await access.release(leases[index])
        #expect(scope.counts(f.old) == [2, oldStops[step], 0])
        #expect(scope.counts(f.chosen) == [2, newStops[step], 0])
    }
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.counts(f.chosen) == [2, 2, 0])
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: ["bookmark", "start"])
func p201LeaseRebindFailedStaleRepairKeepsOldTokenReleasable(kind: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let old = try await access.acquire(.root(id, file: f.old))
    let bytes = try Data(contentsOf: f.store.url)
    codec.relocated = f.chosen; codec.stale = true
    if kind == "bookmark" {
        codec.creationFails = true
        await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.acquire(.root(id, file: f.chosen)) }
        #expect(scope.counts(f.chosen) == [1, 1, 0])
    } else {
        scope.rejected = f.chosen
        await #expect(throws: FileAccessError.startFailed) { try await access.acquire(.root(id, file: f.chosen)) }
        #expect(scope.counts(f.chosen) == [0, 0, 1])
    }
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(old.url == f.old && old.rootID == id)
    #expect(scope.counts(f.old) == [2, 1, 0])
    await access.release(old)
    #expect(scope.counts(f.old) == [2, 2, 0])
    await access.release(old)
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2))) func p201LeaseRebindSameURLStaleAcquiresShareOneRefresh() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    codec.stale = true
    let a = try await access.acquire(.root(id, file: f.old))
    let b = try await access.acquire(.root(id, file: f.old.appendingPathComponent("a.png")))
    #expect(a.url == f.old && b.url == f.old)
    #expect(codec.count == 2)
    #expect(try f.store.load().count == 1)
    #expect(scope.counts(f.old) == [2, 1, 0])
    await access.release(a)
    #expect(scope.counts(f.old) == [2, 1, 0])
    await access.release(b)
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func p201LeaseRebindReturnToHeldURLPublishesLatestRoot(stale: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let a = try await access.acquire(.root(id, file: f.old))
    codec.relocated = f.chosen; codec.stale = true
    let b = try await access.acquire(.root(id, file: f.chosen))
    #expect(await access.rootURL(id) == f.chosen)
    #expect(codec.count == 2)
    codec.relocated = f.old; codec.stale = stale
    let c = try await access.acquire(.root(id, file: f.old))
    #expect(a.url == f.old && b.url == f.chosen && c.url == f.old)
    #expect(await access.rootURL(id) == f.old)
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [1, 0, 0])
    #expect(codec.count == (stale ? 3 : 2))
    #expect(try f.store.load().first?.bookmark == Data((stale ? f.old.path : f.chosen.path).utf8))
    await #expect(throws: FileAccessError.outsideRoot) { try await access.acquire(.root(id, file: f.chosen)) }
    if stale {
        await access.release(a)
        #expect(scope.counts(f.old) == [2, 1, 0])
        await access.release(b)
        #expect(scope.counts(f.chosen) == [1, 1, 0])
        #expect(scope.counts(f.old) == [2, 1, 0])
        await access.release(c)
        #expect(Array(scope.stops.suffix(2)) == [f.chosen, f.old])
    } else {
        await access.release(c)
        #expect(scope.counts(f.old) == [2, 1, 0])
        await access.release(a)
        #expect(scope.counts(f.old) == [2, 2, 0])
        #expect(scope.counts(f.chosen) == [1, 0, 0])
        await access.release(b)
        #expect(Array(scope.stops.suffix(2)) == [f.old, f.chosen])
    }
    for lease in [a, b, c] { await access.release(lease) }
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.counts(f.chosen) == [1, 1, 0])
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2))) func p201LeaseRebindReturnRefreshFailureKeepsBothHeldSessions() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    let id = try await access.grant(folder: f.old)
    let a = try await access.acquire(.root(id, file: f.old))
    codec.relocated = f.chosen; codec.stale = true
    let b = try await access.acquire(.root(id, file: f.chosen))
    let bytes = try Data(contentsOf: f.store.url)
    let records = await access.records()
    codec.relocated = f.old; codec.creationFails = true
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.acquire(.root(id, file: f.old)) }
    #expect(try Data(contentsOf: f.store.url) == bytes)
    #expect(await access.records() == records)
    #expect(await access.rootURL(id) == nil)
    #expect(codec.count == 2)
    #expect(scope.counts(f.old) == [2, 1, 0])
    #expect(scope.counts(f.chosen) == [1, 0, 0])
    await access.release(a)
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.counts(f.chosen) == [1, 0, 0])
    await access.release(b)
    await access.release(a); await access.release(b)
    #expect(scope.counts(f.old) == [2, 2, 0])
    #expect(scope.counts(f.chosen) == [1, 1, 0])
    #expect(Array(scope.stops.suffix(2)) == [f.old, f.chosen])
    #expect(scope.balanced)
}
