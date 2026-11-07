import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

/// Only the asynchronous coordinator hop and disk scan use real scheduling; debounce uses the fake clock.
@MainActor private func i142WatchedSettles(_ condition: () -> Bool) async throws -> Bool {
    while !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Test(.timeLimit(.minutes(2))) @MainActor func i142WI2WatchedCountFollowsCompleteFilteredReplacement() async throws {
    let w = try await WatchedCoordinator(files: ["F/a.png", "F/b.jpg", "F/c.png"])
    defer { w.coordinator.end(); w.f.remove() }
    let c = w.coordinator
    try await c.begin(folder: w.url("F"), rootID: w.rootID).value
    c.setConditions(.init(selectedExtensions: ["png"]))
    #expect(w.names() == ["a.png", "c.png"])
    #expect(c.completedImageCount == 2)
    let initialGeneration = w.generation
    w.write("F/d.png"); w.write("F/e.jpg")
    // Explicit fake source → real WatchHub → fake debounce → real coordinator/FolderBrowser.
    #expect(w.f.source.starts == 1)
    w.f.source.emit([.changed(w.url("F/d.png")), .changed(w.url("F/e.jpg"))], on: w.f.url("root"))
    w.f.clock.advance(by: WatchHub.debounceMilliseconds)
    try #require(await i142WatchedSettles {
        w.names() == ["a.png", "c.png", "d.png"] && w.generation > initialGeneration && !c.isScanning
    }, "Injected additions did not produce a complete filtered replacement")
    #expect(c.snapshot?.isComplete == true)
    #expect(c.sourceSnapshot?.navigationEntries.count == 5)
    #expect(c.completedImageCount == 3)
    #expect(c.completedImageCount == c.snapshot?.navigationEntries.count)
    #expect(!c.isReadingFolder && !c.isScanning)
    let addedGeneration = w.generation
    for name in ["a.png", "c.png", "d.png"] { w.delete("F/" + name) }
    w.f.source.emit(["F/a.png", "F/c.png", "F/d.png"].map { .changed(w.url($0)) }, on: w.f.url("root"))
    w.f.clock.advance(by: WatchHub.debounceMilliseconds)
    try #require(await i142WatchedSettles {
        w.names().isEmpty && w.generation > addedGeneration && !c.isScanning
    }, "Injected removals did not produce a complete empty projection")
    #expect(c.snapshot?.isComplete == true)
    #expect(c.sourceSnapshot?.navigationEntries.count == 2)
    #expect(c.completedImageCount == 0)
    #expect(c.completedImageCount == c.snapshot?.navigationEntries.count)
    c.setConditions(.init())
    #expect(w.names() == ["b.jpg", "e.jpg"])
    #expect(c.completedImageCount == 2)
    #expect(!c.isReadingFolder && !c.isScanning)
}
