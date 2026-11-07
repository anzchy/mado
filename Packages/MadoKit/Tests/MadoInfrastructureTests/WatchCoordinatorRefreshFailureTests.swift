import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

/// FolderBrowser that fails the next scan once when armed.
private actor FlakyScanner: FolderScanning {
    private let inner = FolderBrowser()
    private var failNext = false
    func arm() { failNext = true }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        if failNext { failNext = false; throw CocoaError(.fileReadUnknown) }
        try await inner.scan(in: folder, root: root, options: options, emit: emit)
    }
}

@MainActor private final class Viewed {
    let w: WatchedCoordinator, scanner = FlakyScanner(), c: FolderScanCoordinator
    init() async throws {
        w = try await WatchedCoordinator(files: ["F/a.png", "F/b.png"])
        c = FolderScanCoordinator(access: w.f.access, scanner: scanner, trace: w.trace, watcher: w.f.hub)
        c.host = w.host
        try await c.begin(folder: w.url("F"), rootID: w.rootID, input: w.url("F/a.png")).value
        w.host.reset(); w.host.ended = 0
    }
    var names: [String] { c.snapshot?.entries.map(\.url.lastPathComponent) ?? [] }
    var failures: Int { w.trace.ends.filter { $0.outcome == .failed }.count }
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorFailedRefreshShowsFailureAndDropsAGoneImage() async throws {
    // The viewed folder deleted, or moved away: the failure surface shows and the gone image is not kept on screen.
    for move in [false, true] {
        let v = try await Viewed(); defer { v.w.f.remove() }
        let prior = try #require(v.c.sourceSnapshot)
        if move { try FileManager.default.moveItem(at: v.w.url("F"), to: v.w.url("G/F-moved")) } else { v.w.delete("F") }
        v.w.changed(["F"])
        try await waitUntil("move=\(move)") { v.failures == 1 }
        try await waitUntil("move=\(move) image kept") { v.w.host.cleared == 1 }
        #expect(v.c.failure != nil && v.c.failureReason != nil, "move=\(move)")
        #expect(v.c.currentItemID == nil && v.c.currentURL == nil, "move=\(move)")
        #expect(v.w.host.ended >= 1 && v.w.host.opened.isEmpty && v.w.host.didStart == 0, "move=\(move)")
        #expect(v.c.sourceSnapshot == prior, "move=\(move)")
        #expect(v.w.f.source.active == 1, "move=\(move) watch kept")

        // The folder coming back recovers on the next hint and clears the failure.
        v.w.write("F/a.png"); v.w.write("F/c.png"); v.w.changed(["F/c.png"])
        try await waitUntil("move=\(move)") { v.names == ["a.png", "c.png"] }
        #expect(v.c.failure == nil, "move=\(move)")
        #expect(!v.w.host.completed.isEmpty, "move=\(move)")
    }

    // A failure while the Current Item's file still exists keeps the image and the entries, and shows the failure.
    do {
        let v = try await Viewed(); defer { v.w.f.remove() }
        let prior = try #require(v.c.sourceSnapshot)
        await v.scanner.arm()
        v.w.hint([.mustRescan])
        try await waitUntil { v.failures == 1 }
        #expect(v.c.failure != nil)
        #expect(v.c.currentURL?.lastPathComponent == "a.png" && v.c.currentItemID == v.w.id("F/a.png"))
        #expect(v.w.host.cleared == 0 && v.w.host.opened.isEmpty)
        #expect(v.c.sourceSnapshot?.entries == prior.entries)
        // The next hint with unchanged entries still clears the failure.
        v.w.hint([.mustRescan])
        try await waitUntil { v.c.failure == nil }
        #expect(v.c.currentURL?.lastPathComponent == "a.png" && v.w.host.cleared == 0)
    }

    // Retry after a failed refresh rescans the folder as a user scan.
    do {
        let v = try await Viewed(); defer { v.w.f.remove() }
        v.w.delete("F")
        v.w.changed(["F"])
        try await waitUntil { v.failures == 1 && v.c.failure != nil }
        v.w.write("F/b.png")
        let retried = try #require(v.c.retry())
        try await retried.value
        #expect(v.c.failure == nil)
        #expect(v.names == ["b.png"])
        #expect(v.w.host.didStart == 1 && !v.w.host.completed.isEmpty)
    }
}
