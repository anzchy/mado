import Foundation
import Observation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@MainActor final class RecordingScanHost: FolderScanHost {
    var didStart = 0, opened: [URL] = [], cleared = 0, completed: [Int] = []
    var rememberHook: (@MainActor () async -> Void)?
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opened.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { await rememberHook?() }
    func clearFolderImageForNoMatches() { cleared += 1 }
    func folderScanDidComplete(count: Int) { completed.append(count) }
    func folderScanDidStart() { didStart += 1 }
    var ended = 0
    func folderScanDidEnd() { ended += 1 }
    func reset() { didStart = 0; opened = []; cleared = 0; completed = [] }
}

@MainActor final class RecordingScanTrace: FolderScanTracing {
    var begins: [(generation: UInt64, folder: URL)] = []
    var ends: [(outcome: FolderScanOutcome, generation: UInt64)] = []
    func begin(generation: UInt64, folderURL: URL) { begins.append((generation, folderURL)) }
    func firstBatch(count: Int, generation: UInt64) { }
    func complete(count: Int, generation: UInt64) { }
    func end(outcome: FolderScanOutcome, generation: UInt64) { ends.append((outcome, generation)) }
}

/// Samples the visible snapshot and Reading State after every observed change, one MainActor turn later.
@MainActor final class ObservationSamples {
    private(set) var values: [(snapshot: FolderSnapshot?, reading: Bool)] = []
    private let coordinator: FolderScanCoordinator
    init(_ coordinator: FolderScanCoordinator) { self.coordinator = coordinator; track() }
    private func track() {
        values.append((coordinator.snapshot, coordinator.isReadingFolder))
        withObservationTracking { _ = coordinator.snapshot; _ = coordinator.isReadingFolder } onChange: {
            Task { @MainActor in self.track() }
        }
    }
}

private actor EntrySink {
    var entries: [FolderEntry] = []
    func add(_ batch: [FolderEntry]) { entries += batch }
}

/// Real WatchHub (fake source and clock), real FileAccess and FolderBrowser over `root/…`, granted as one root.
@MainActor final class WatchedCoordinator {
    let f: WatchFixture
    let rootID: AccessRootID
    let host = RecordingScanHost()
    let trace = RecordingScanTrace()
    let coordinator: FolderScanCoordinator
    init(files: [String], folders: [String] = ["root/F", "root/G"]) async throws {
        f = try WatchFixture(folders: folders)
        rootID = try await f.access.grant(folder: f.url("root"))
        coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), trace: trace, watcher: f.hub)
        coordinator.host = host
        for file in files { write(file) }
    }
    func url(_ path: String) -> URL { f.url("root/" + path) }
    func write(_ path: String) {
        let file = url(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
    }
    func delete(_ path: String) { try? FileManager.default.removeItem(at: url(path)) }
    func hint(_ hints: [FolderChangeHint], wait: Int = 200) {
        f.source.emit(hints, on: f.url("root"))
        f.clock.advance(by: wait)
    }
    func changed(_ paths: [String], wait: Int = 200) { hint(paths.map { .changed(url($0)) }, wait: wait) }
    var generation: UInt64 { coordinator.sourceSnapshot?.version.generation ?? 0 }
    /// Visible entries in projected order, relative to `folder`.
    func names(_ folder: String = "F") -> [String] {
        coordinator.snapshot?.entries.map { String($0.relativePath.dropFirst(folder.count + 1)) } ?? []
    }
    func id(_ path: String) -> ItemID { .rootRelative(rootID: rootID, relativePath: path) }
    func turns(_ count: Int = 3) async { for _ in 0..<count { await Task.yield() } }
    var scopeBalanced: Bool { let counts = f.scope.counts; return counts[0] == counts[1] }
    func freshScan(recursive: Bool) async throws -> Set<ItemID> {
        let sink = EntrySink()
        try await FolderBrowser().scan(in: url("F"), root: ItemIdentityRoot(id: rootID, url: f.url("root")),
            options: .init(recursive: recursive)) { await sink.add($0) }
        return Set(await sink.entries.map(\.itemID))
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorRefreshIsSilentAndConvergesOnDisk() async throws {
    let w = try await WatchedCoordinator(files: ["F/a.png", "F/b.png", "G/g.png"]); defer { w.f.remove() }
    let c = w.coordinator
    try await c.begin(folder: w.url("F"), rootID: w.rootID).value
    let prior = try #require(c.sourceSnapshot)
    w.host.reset()
    let samples = ObservationSamples(c)
    let grid = FolderGridProjection()
    #expect(grid.apply(prior))

    // Row 1: a hint picks up a new file silently, with a generation the grid accepts.
    w.write("F/c.png"); w.changed(["F/c.png"])
    try await waitUntil { w.names() == ["a.png", "b.png", "c.png"] }
    let fresh = try #require(c.sourceSnapshot)
    #expect(fresh.isComplete)
    #expect(fresh.version.generation > prior.version.generation)
    #expect(grid.apply(fresh))
    #expect(w.host.didStart == 0)
    #expect(w.host.opened.isEmpty)
    try await waitUntil { samples.values.count >= 2 } // the sampler records one MainActor turn after the change
    #expect(samples.values.allSatisfy { $0.snapshot?.isComplete == true && !$0.reading })

    // W1/W2: a sibling folder and a flat subfolder never refresh; a positive sentinel ends the negative check.
    let n0 = w.trace.begins.count
    w.write("G/x.png"); w.changed(["G/x.png"], wait: 1000)
    w.write("F/sub/x.png"); w.changed(["F/sub/x.png"], wait: 1000)
    await w.turns()
    #expect(w.trace.begins.count == n0)
    w.write("F/s.png"); w.changed(["F/s.png"])
    try await waitUntil { w.names().contains("s.png") }
    #expect(w.trace.begins.count == n0 + 1)
    #expect(!w.names().contains("sub/x.png"))

    // Row 2: nothing changed on disk, so nothing is swapped.
    let settled = try #require(c.sourceSnapshot)
    w.host.reset()
    w.hint([.mustRescan])
    let unchanged = c.refresh()
    #expect(unchanged != nil)
    try await unchanged?.value
    #expect(c.sourceSnapshot?.version == settled.version)
    #expect(c.sourceSnapshot?.entries == settled.entries)
    #expect(w.host.opened.isEmpty)

    // Row 3: a flat refresh keeps subfolders, hidden files and package contents out.
    w.write("F/sub/n.png"); w.write("F/.h.png"); w.write("F/p.app/i.png")
    w.hint([.mustRescan])
    let flat = c.refresh()
    #expect(flat != nil)
    try await flat?.value
    #expect(w.names() == ["a.png", "b.png", "c.png", "s.png"])

    // Row 4: recursive and conditions carry into the refresh; the recursive re-subscription keeps the stream.
    c.setConditions(.init(sort: .name, direction: .descending))
    try await c.setRecursiveEnabled(true)?.value
    w.write("F/sub/m.png"); w.changed(["F/sub/m.png"])
    try await waitUntil { w.names().contains("sub/m.png") }
    #expect(Set(w.names()) == ["a.png", "b.png", "c.png", "s.png", "sub/n.png", "sub/x.png", "sub/m.png"])
    #expect(c.conditions.direction == .descending)
    let visible = c.snapshot?.entries.map(\.url.lastPathComponent) ?? []
    #expect(visible == visible.sorted { $0.localizedStandardCompare($1) == .orderedDescending })
    #expect(w.f.source.starts == 1)
    #expect(w.f.source.stops == 0)

    // Property: random edits, a hint and quiescence converge on a fresh scan with the same options.
    w.host.reset()
    var generations = [w.generation]
    let pool = (0..<8).map { "F/p\($0).png" } + ["F/sub/q.png"]
    for seed in UInt64(0)..<10 {
        var rng = SplitMix64(seed: 0x2007_0000 + seed)
        func edit() -> [String] {
            (0..<Int.random(in: 1...5, using: &rng)).map { _ in
                let path = pool[Int.random(in: 0..<pool.count, using: &rng)]
                if FileManager.default.fileExists(atPath: w.url(path).path) { w.delete(path) } else { w.write(path) }
                return path
            }
        }
        let touched = edit()
        let begins = w.trace.begins.count
        w.hint([rng.next() % 3 == 0 ? .mustRescan : .changed(w.url(touched[touched.count - 1]))])
        if rng.next() % 10 < 3 {
            try await waitUntil("seed=\(seed) no refresh began") { w.trace.begins.count > begins }
            let more = edit()
            w.changed([more[more.count - 1]])
        }
        let expected = try await w.freshScan(recursive: c.recursiveEnabled)
        try await waitUntil("seed=\(seed) got=\(w.names()) expected=\(expected)") {
            Set(c.sourceSnapshot?.entries.map(\.itemID) ?? []) == expected
        }
        #expect(c.currentItemID.map { c.snapshot?.navigationIndex(for: $0) != nil } ?? true, "seed=\(seed)")
        generations.append(w.generation)
    }
    #expect(generations == generations.sorted())
    #expect(w.host.didStart == 0)
}

/// I-1 (#137): a real scan of a folder holding only a non-image file and a subfolder is empty; real refreshes toggle it.
@Test @MainActor func realEmptyFolderScanSetsIsEmptyFolderAndWatchedRefreshClearsIt() async throws {
    let w = try await WatchedCoordinator(files: ["F/notes.txt"], folders: ["root/F", "root/F/sub"]); defer { w.f.remove() }
    let c = w.coordinator
    try await c.begin(folder: w.url("F"), rootID: w.rootID).value
    #expect(c.isEmptyFolder, "a non-image file and a subfolder are not images")
    w.write("F/a.png")
    try await c.refresh()?.value
    #expect(!c.isEmptyFolder, "an image arrived")
    w.delete("F/a.png")
    try await c.refresh()?.value
    #expect(c.isEmptyFolder, "the image was removed")
    w.write("F/sub/b.png")
    try await c.setRecursiveEnabled(true)?.value
    #expect(!c.isEmptyFolder, "the subfolder image counts with Include Subfolders")
}
