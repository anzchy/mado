import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func t230ReselectionGrantExcludesOnlyLostRootAndDefaultsStillMerge() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(), codec = ReconnectBookmarks()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T230")
    let originalID = try await access.grant(folder: f.old)
    let original = try #require(try f.store.load().first)
    let identity = try #require(try URLRecoveryIdentityResourceReader().identity(for: f.old))
    let moved = f.base.appendingPathComponent("original-moved")
    try FileManager.default.moveItem(at: f.old, to: moved)
    try FileManager.default.createDirectory(at: f.old, withIntermediateDirectories: true)
    #expect(try URLRecoveryIdentityResourceReader().identity(for: f.old) != identity)
    let selected = try await access.grant(folder: f.old, excludingRoot: originalID)
    #expect(selected != originalID)
    #expect(try f.store.load().count == 2)
    #expect(try f.store.load().first { $0.id == originalID } == original)
    #expect(try await access.grant(folder: f.old, excludingRoot: originalID) == selected)
    #expect(try f.store.load().count == 2)
    // The optional parameter cannot change ordinary callers' merge behavior.
    let another = try await access.grant(folder: f.chosen)
    #expect(try await access.grant(folder: f.chosen) == another)
    #expect(try await access.grant(folder: f.chosen, excludingRoot: originalID) == another)
    #expect(try f.store.load().count == 3)
    #expect(scope.balanced)
}
