import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorMovesDeletedCurrentToNeighbour() async throws {
    struct Row {
        let name: String, files: [String], conditions: FolderViewConditions?, current: String, deleted: [String]
        let expected: String?, opened: [String], cleared: Int
    }
    let png: Set<String> = ["png"]
    let rows = [
        Row(name: "M1", files: ["a.png", "b.png", "c.png"], conditions: nil, current: "b.png", deleted: ["b.png"],
            expected: "c.png", opened: ["c.png"], cleared: 0),
        Row(name: "M2", files: ["a.png", "c.png"], conditions: nil, current: "c.png", deleted: ["c.png"],
            expected: "a.png", opened: ["a.png"], cleared: 0),
        Row(name: "M3", files: ["a.png"], conditions: nil, current: "a.png", deleted: ["a.png"],
            expected: nil, opened: [], cleared: 1),
        Row(name: "M4", files: ["a.png", "b.png", "c.png", "d.png"], conditions: nil, current: "b.png",
            deleted: ["b.png", "c.png"], expected: "d.png", opened: ["d.png"], cleared: 0),
        Row(name: "M5", files: ["a.png", "b.jpg", "c.png"], conditions: .init(selectedExtensions: png), current: "c.png",
            deleted: ["c.png"], expected: "a.png", opened: ["a.png"], cleared: 0),
        Row(name: "M6", files: ["a.png", "b.png", "c.png"], conditions: .init(sort: .name, direction: .descending),
            current: "b.png", deleted: ["b.png"], expected: "a.png", opened: ["a.png"], cleared: 0),
        Row(name: "M7", files: ["a.png", "b.png", "c.png"], conditions: nil, current: "b.png", deleted: ["a.png"],
            expected: "b.png", opened: [], cleared: 0),
    ]
    for row in rows {
        let w = try await WatchedCoordinator(files: row.files.map { "F/\($0)" }); defer { w.f.remove() }
        let c = w.coordinator
        try await c.begin(folder: w.url("F"), rootID: w.rootID, input: w.url("F/\(row.current)")).value
        if let conditions = row.conditions { c.setConditions(conditions) }
        w.host.reset()
        let g0 = w.generation
        for file in row.deleted { w.delete("F/\(file)") }
        w.changed(row.deleted.map { "F/\($0)" })
        try await waitUntil("\(row.name) no refresh") { w.generation > g0 }
        #expect(c.currentURL?.lastPathComponent == row.expected, "\(row.name)")
        #expect(c.currentItemID == row.expected.map { w.id("F/\($0)") }, "\(row.name)")
        #expect(w.host.opened.map(\.lastPathComponent) == row.opened, "\(row.name)")
        #expect(w.host.cleared == row.cleared, "\(row.name)")
    }

    // M8/M9: the refresh anchors on the item the user navigated to, not on the scan's input.
    let w = try await WatchedCoordinator(files: ["F/a.png", "F/b.png", "F/c.png"]); defer { w.f.remove() }
    let c = w.coordinator
    try await c.begin(folder: w.url("F"), rootID: w.rootID, input: w.url("F/a.png")).value
    #expect(c.move(.next))
    #expect(c.currentURL?.lastPathComponent == "b.png")
    w.host.reset()
    var g0 = w.generation
    w.write("F/d.png"); w.changed(["F/d.png"])
    try await waitUntil("M8 no refresh") { w.generation > g0 }
    #expect(c.currentURL?.lastPathComponent == "b.png")
    #expect(c.currentItemID == w.id("F/b.png"))
    #expect(w.host.opened.isEmpty)
    g0 = w.generation
    w.delete("F/b.png"); w.changed(["F/b.png"])
    try await waitUntil("M9 no refresh") { w.generation > g0 }
    #expect(c.currentURL?.lastPathComponent == "c.png")
    #expect(w.host.opened.map(\.lastPathComponent) == ["c.png"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func watchedCoordinatorRefreshYieldsToUserScanAndKeepsStream() async throws {
    let gFolder = { (w: WatchedCoordinator) in SnapshotVersion(rootID: w.rootID, folder: w.url("G"), generation: 0).folder }

    // X1: the subscription exists during the scan; a hint that arrives then refreshes once it completes.
    do {
        let w = try await WatchedCoordinator(files: ["F/a.png"]); defer { w.f.remove() }
        w.host.rememberHook = {
            #expect(w.coordinator.isScanning)
            w.write("F/late.png"); w.changed(["F/late.png"])
            await Task.yield()
        }
        try await w.coordinator.begin(folder: w.url("F"), rootID: w.rootID).value
        try await waitUntil { w.names() == ["a.png", "late.png"] }
    }

    // X2: a user scan of another folder supersedes a refresh in flight.
    do {
        let w = try await WatchedCoordinator(files: ["F/a.png", "G/g.png"]); defer { w.f.remove() }
        let c = w.coordinator
        try await c.begin(folder: w.url("F"), rootID: w.rootID).value
        w.write("F/b.png")
        let refresh = c.refresh()
        #expect(refresh != nil)
        let user = c.begin(folder: w.url("G"), rootID: w.rootID)
        let userGeneration = c.generation
        try await user.value
        _ = try? await refresh?.value
        await w.turns()
        #expect(c.sourceSnapshot?.version.folder == gFolder(w))
        #expect(w.names("G") == ["g.png"])
        #expect(c.sourceSnapshot?.version.generation == userGeneration)
    }

    // X3: end() drops a refresh in flight and releases the stream and the scope.
    do {
        let w = try await WatchedCoordinator(files: ["F/a.png"]); defer { w.f.remove() }
        let c = w.coordinator
        try await c.begin(folder: w.url("F"), rootID: w.rootID).value
        w.write("F/b.png")
        let refresh = c.refresh()
        #expect(refresh != nil)
        c.end()
        _ = try? await refresh?.value
        await w.turns()
        #expect(c.snapshot == nil)
        #expect(c.sourceSnapshot == nil)
        try await waitUntil { w.f.source.stops == 1 && w.scopeBalanced }
        #expect(w.f.source.starts == 1)
    }

    // X4/X4b: F → G on one root keeps one stream and leaves no F subscriber behind.
    do {
        let w = try await WatchedCoordinator(files: ["F/a.png", "G/g.png"]); defer { w.f.remove() }
        let c = w.coordinator
        try await c.begin(folder: w.url("F"), rootID: w.rootID).value
        try await c.begin(folder: w.url("G"), rootID: w.rootID).value
        #expect(w.f.source.starts == 1)
        #expect(w.f.source.stops == 0)
        let n0 = w.trace.begins.count
        #expect(n0 == 2)
        w.write("F/x.png"); w.changed(["F/x.png"], wait: 1000)
        await w.turns()
        #expect(w.trace.begins.count == n0)
        w.write("G/s.png"); w.changed(["G/s.png"])
        try await waitUntil { w.names("G").contains("s.png") }
        #expect(w.trace.begins.count == n0 + 1)
        #expect(w.trace.begins.last.map { canonicalPath($0.folder) } == canonicalPath(w.url("G")))
        #expect(w.f.source.starts == 1)
        #expect(w.f.source.stops == 0)
        c.end()
        try await waitUntil { w.f.source.stops == 1 && w.f.source.active == 0 && w.scopeBalanced }
    }

    // X5: a folder on another root stops root 1's stream and starts root 2's.
    do {
        let w = try await WatchedCoordinator(files: ["F/a.png"], folders: ["root/F", "other"]); defer { w.f.remove() }
        let other = try await w.f.access.grant(folder: w.f.url("other"))
        FileManager.default.createFile(atPath: w.f.url("other/h.png").path, contents: Data())
        let c = w.coordinator
        try await c.begin(folder: w.url("F"), rootID: w.rootID).value
        try await c.begin(folder: w.f.url("other"), rootID: other).value
        try await waitUntil { w.f.source.stops == 1 && w.f.source.active == 1 }
        #expect(w.f.source.startURLs == [canonicalPath(w.f.url("root")), canonicalPath(w.f.url("other"))])
    }

    // X6: a revoked root fails the scan and starts no stream.
    do {
        let w = try await WatchedCoordinator(files: []); defer { w.f.remove() }
        w.f.bookmarks.fails = true
        let task = w.coordinator.begin(folder: w.url("F"), rootID: w.rootID)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(w.coordinator.failure is FileAccessError)
        #expect(w.f.source.starts == 0)
    }

    // X7: a failed scan releases the subscription; retry subscribes again and stays watched.
    do {
        let w = try await WatchedCoordinator(files: [], folders: ["root"]); defer { w.f.remove() }
        let c = w.coordinator
        let task = c.begin(folder: w.url("missing"), rootID: w.rootID)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(c.failure != nil)
        try await waitUntil { w.f.source.active == 0 && w.f.source.stops == 1 && w.scopeBalanced }
        #expect(w.f.source.starts == 1)
        w.write("missing/a.png")
        let retried = c.retry()
        #expect(retried != nil)
        try await retried?.value
        #expect(w.f.source.starts == 2)
        #expect(w.f.source.active == 1)
        #expect(w.names("missing") == ["a.png"])
        w.write("missing/b.png"); w.changed(["missing/b.png"])
        try await waitUntil { w.names("missing") == ["a.png", "b.png"] }
    }

    // X8: Cancel Reading back to a complete grid keeps it watched on the same stream.
    do {
        let w = try await WatchedCoordinator(files: ["F/a.png", "G/g.png"]); defer { w.f.remove() }
        let c = w.coordinator
        let session = ViewerSession()
        session.folderScan = c
        try await c.begin(folder: w.url("F"), rootID: w.rootID).value
        session.beginFolderEntry(shownImage: nil, hasCompleteGrid: true)
        let reading = c.begin(folder: w.url("G"), rootID: w.rootID)
        #expect(session.cancelFolderEntry() == .grid)
        _ = try? await reading.value
        #expect(c.sourceSnapshot?.version.folder == SnapshotVersion(rootID: w.rootID, folder: w.url("F"), generation: 0).folder)
        w.write("F/new.png"); w.changed(["F/new.png"])
        try await waitUntil { w.names().contains("new.png") }
        #expect(w.f.source.starts == 1)
        #expect(w.f.source.stops == 0)
    }
}
