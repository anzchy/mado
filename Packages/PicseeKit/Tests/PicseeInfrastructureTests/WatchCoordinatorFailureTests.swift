import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorFallsBackHonestlyWhenTheWatchFails() async throws {
    // A refused stream: the scan still completes, but no watch is pretended and the state is visible.
    let w = try await WatchedCoordinator(files: ["F/a.png", "F/b.png"], folders: ["root/F", "other/H"]); defer { w.f.remove() }
    let c = w.coordinator
    w.f.source.refusals = 1
    try await c.begin(folder: w.url("F"), rootID: w.rootID).value
    #expect(w.names() == ["a.png", "b.png"])
    #expect(c.isWatchUnavailable)
    #expect(w.f.source.active == 0)
    try await waitUntil { w.scopeBalanced }

    // The hub's foreground reconcile reaches only live watches, so nothing refreshes this window.
    w.write("F/c.png")
    let begins = w.trace.begins.count
    w.f.hub.reconcileAll()
    await w.turns()
    #expect(w.trace.begins.count == begins && w.names() == ["a.png", "b.png"])

    // The window's own foreground fallback subscribes again and rescans silently.
    w.host.reset()
    let fallback = try #require(c.reconcileUnwatched())
    try await fallback.value
    #expect(w.names() == ["a.png", "b.png", "c.png"])
    #expect(!c.isWatchUnavailable)
    #expect(w.f.source.active == 1 && w.f.source.starts == 1)
    #expect(w.host.didStart == 0)
    #expect(c.reconcileUnwatched() == nil)
    w.write("F/d.png"); w.changed(["F/d.png"])
    try await waitUntil { w.names().contains("d.png") }

    // Switching to another root whose stream is refused stops the old root's watch and holds nothing.
    let other = try await w.f.access.grant(folder: w.f.url("other"))
    w.write("../other/H/h.png")
    w.f.source.refusals = 1
    try await c.begin(folder: w.f.url("other/H"), rootID: other).value
    #expect(c.isWatchUnavailable)
    try await waitUntil { w.f.source.active == 0 && w.scopeBalanced }
    #expect(w.f.source.stops == 1)

    // After end() there is nothing to fall back for.
    c.end()
    #expect(!c.isWatchUnavailable)
    let starts = w.f.source.starts
    #expect(c.reconcileUnwatched() == nil)
    await w.turns()
    #expect(w.f.source.starts == starts && w.scopeBalanced)
}
