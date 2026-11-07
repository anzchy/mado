import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorFollowsAliasDeletion() async throws {
    // Deleting the alias being viewed keeps the same image under the URL that still exists.
    let alias = try await WatchedCoordinator(files: ["F/b.png", "F/c.png"]); defer { alias.f.remove() }
    try FileManager.default.createSymbolicLink(at: alias.url("F/a.png"), withDestinationURL: alias.url("F/c.png"))
    let viewer = alias.coordinator
    try await viewer.begin(folder: alias.url("F"), rootID: alias.rootID, input: alias.url("F/a.png")).value
    #expect(viewer.currentItemID == alias.id("F/c.png"))
    alias.host.reset()
    let g0 = alias.generation
    alias.delete("F/a.png"); alias.changed(["F/a.png"])
    try await waitUntil { alias.generation > g0 }
    #expect(viewer.currentItemID == alias.id("F/c.png"))
    #expect(viewer.currentURL?.lastPathComponent == "c.png")
    #expect(alias.host.opened.map(\.lastPathComponent) == ["c.png"])
}
