import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) @MainActor func issue140WatchedDeleteUnderExtensionFilterNeverFlashesNoMatches() async throws {
    let w = try await WatchedCoordinator(files: ["F/a.png", "F/b.png", "F/c.png", "F/hidden.jpg"])
    defer { w.f.remove() }
    let c = w.coordinator
    try await c.begin(folder: w.url("F"), rootID: w.rootID, input: w.url("F/b.png")).value
    c.setConditions(.init(selectedExtensions: ["png"]))
    let samples = ObservationSamples(c)
    w.host.reset()
    let priorGeneration = w.generation
    w.delete("F/b.png"); w.changed(["F/b.png"])
    try await waitUntil { w.generation > priorGeneration && c.currentURL?.lastPathComponent == "c.png" }
    #expect(c.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["a.png", "c.png"])
    #expect(c.currentItemID == w.id("F/c.png"))
    #expect(w.host.opened.map(\.lastPathComponent) == ["c.png"])
    #expect(w.host.cleared == 0 && !c.hasNoMatches)
    #expect(samples.values.allSatisfy { $0.snapshot?.isComplete == true && !$0.snapshot!.navigationEntries.isEmpty })
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue140WatchedRenameAndDeletePreserveFilenameSearchCurrent() async throws {
    let w = try await WatchedCoordinator(files: ["F/match-a.png", "F/match-b.png", "F/match-c.png", "F/other.png"])
    defer { w.f.remove() }
    let c = w.coordinator
    try await c.begin(folder: w.url("F"), rootID: w.rootID, input: w.url("F/match-b.png")).value
    let search = GridSearchState()
    search.setTerm("match", currentItemID: c.currentItemID)
    let originalID = try #require(c.currentItemID)
    let samples = ObservationSamples(c)
    w.host.reset()
    try FileManager.default.moveItem(at: w.url("F/match-b.png"), to: w.url("F/match-d.png"))
    var generation = w.generation
    w.changed(["F/match-b.png", "F/match-d.png"])
    try await waitUntil { w.generation > generation && c.currentURL?.lastPathComponent == "match-d.png" }
    #expect(c.currentItemID == originalID)
    #expect(search.project(try #require(c.sourceSnapshot)).navigationEntries.map(\.url.lastPathComponent) ==
        ["match-a.png", "match-c.png", "match-d.png"])
    #expect(search.term == "match")
    w.host.reset()
    generation = w.generation
    w.delete("F/match-d.png"); w.changed(["F/match-d.png"])
    try await waitUntil { w.generation > generation &&
        c.sourceSnapshot?.entries.contains(where: { $0.url.lastPathComponent == "match-d.png" }) == false }
    let filtered = search.project(try #require(c.sourceSnapshot))
    #expect(filtered.navigationEntries.map(\.url.lastPathComponent) == ["match-a.png", "match-c.png"])
    #expect(search.term == "match" && !filtered.navigationEntries.isEmpty)
    #expect(w.host.cleared == 0)
    #expect(samples.values.allSatisfy { $0.snapshot?.isComplete == true && !$0.snapshot!.navigationEntries.isEmpty })
}
