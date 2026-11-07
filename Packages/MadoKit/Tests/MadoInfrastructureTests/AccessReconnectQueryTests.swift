import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test(arguments: ["missing", "resolved", "launch-stale", "reconnected", "acquire-stale", "failed"])
func p201RecoveryRootQueryUsesPublishedURLWithoutMutation(state: String) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(); let codec = FakeBookmarks()
    var access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "A")
    var id = AccessRootID()
    var expected: URL?
    if state != "missing" { id = try await access.grant(folder: f.old) }
    switch state {
    case "resolved": expected = f.old
    case "launch-stale":
        codec.relocated = f.chosen; codec.stale = true
        access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
        codec.stale = false; expected = f.chosen
    case "reconnected":
        _ = try await access.reconnect(id, folder: f.chosen)
        expected = f.chosen
    case "acquire-stale":
        codec.relocated = f.chosen; codec.stale = true
        let lease = try await access.acquire(.root(id, file: f.chosen))
        await access.release(lease)
        codec.stale = false; expected = f.chosen
    case "failed":
        codec.fails = true
        access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "B")
        codec.fails = false
    default: break
    }
    let records = await access.records()
    let bytes = try? Data(contentsOf: f.store.url)
    let creations = codec.count
    let oldCounts = scope.counts(f.old); let newCounts = scope.counts(f.chosen)
    #expect(await access.rootURL(id) == expected)
    #expect(await access.rootURL(id) == expected)
    #expect(await access.rootURL(AccessRootID()) == nil)
    #expect(await access.records() == records)
    #expect((try? Data(contentsOf: f.store.url)) == bytes)
    #expect(codec.count == creations)
    #expect(scope.counts(f.old) == oldCounts && scope.counts(f.chosen) == newCounts)
    #expect(scope.balanced)
}
