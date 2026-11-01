import Foundation
import Testing
import PicseeCore
import PicseeApplication

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
    w.changed(["F/d.png", "F/e.jpg"])
    #expect(await mainPoll { w.names() == ["a.png", "c.png", "d.png"] && w.generation > initialGeneration })
    #expect(c.snapshot?.isComplete == true)
    #expect(c.sourceSnapshot?.navigationEntries.count == 5)
    #expect(c.completedImageCount == 3)
    #expect(c.completedImageCount == c.snapshot?.navigationEntries.count)
    #expect(!c.isReadingFolder && !c.isScanning)
    let addedGeneration = w.generation
    for name in ["a.png", "c.png", "d.png"] { w.delete("F/" + name) }
    w.changed(["F/a.png", "F/c.png", "F/d.png"])
    #expect(await mainPoll { w.names().isEmpty && w.generation > addedGeneration })
    #expect(c.snapshot?.isComplete == true)
    #expect(c.sourceSnapshot?.navigationEntries.count == 2)
    #expect(c.completedImageCount == 0)
    #expect(c.completedImageCount == c.snapshot?.navigationEntries.count)
    c.setConditions(.init())
    #expect(w.names() == ["b.jpg", "e.jpg"])
    #expect(c.completedImageCount == 2)
    #expect(!c.isReadingFolder && !c.isScanning)
}
