import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

@Test(.timeLimit(.minutes(2))) @MainActor func issue140MovedEmptyRootPublishesRelocatedSnapshot() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let root = f.url("root"), moved = f.url("moved")
    let id = try await f.access.grant(folder: root)
    let coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    try await coordinator.begin(folder: root, rootID: id).value
    let prior = try #require(coordinator.sourceSnapshot)
    #expect(prior.entries.isEmpty && prior.version.folder == root)

    try FileManager.default.moveItem(at: root, to: moved)
    f.bookmarks.relocated = moved
    try await coordinator.refresh()?.value
    let relocated = try #require(coordinator.sourceSnapshot)
    #expect(relocated.version.folder.standardizedFileURL.pathComponents == moved.standardizedFileURL.pathComponents)
    #expect(relocated.version.generation > prior.version.generation)
    #expect(coordinator.snapshot?.version == relocated.version)
    #expect(relocated.entries.isEmpty)

    FileManager.default.createFile(atPath: moved.appendingPathComponent("later.png").path, contents: Data())
    f.source.emit([.changed(moved.appendingPathComponent("later.png"))], on: moved)
    f.clock.advance(by: 200)
    try await waitUntil { coordinator.sourceSnapshot?.entries.map(\.url.lastPathComponent) == ["later.png"] }

    let settled = try #require(coordinator.sourceSnapshot)
    try await coordinator.refresh()?.value
    #expect(coordinator.sourceSnapshot?.version == settled.version)
}
