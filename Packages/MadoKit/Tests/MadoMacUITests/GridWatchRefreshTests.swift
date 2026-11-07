import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class WatchRefreshHost: ViewerSessionHost {
    var hasImage = true
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() {}
}

/// Holds every thumbnail request until it is cancelled, and records starts and cancellations.
private actor WatchRefreshThumbnailLog {
    struct Counts: Sendable {
        var starts: [ItemID: Int] = [:]
        var cancels: [ItemID: Int] = [:]
        var edges: [ItemID: [Int]] = [:]
        var priorities: [ItemID: [DecodePriority]] = [:]
        func live(_ id: ItemID) -> Int { starts[id, default: 0] - cancels[id, default: 0] }
        func added(since base: Counts, _ id: ItemID) -> Int { starts[id, default: 0] - base.starts[id, default: 0] }
    }
    private var counts = Counts()
    private var waiters: [UUID: (condition: @Sendable (Counts) -> Bool, continuation: CheckedContinuation<Counts, Never>)] = [:]
    func start(_ id: ItemID, edge: Int, priority: DecodePriority) {
        counts.starts[id, default: 0] += 1
        counts.edges[id, default: []].append(edge)
        counts.priorities[id, default: []].append(priority)
        notify()
    }
    /// Pre-#161 assertions compare edges; a coverage's fallback edge is the edge the grid used to request.
    func start(_ id: ItemID, edge coverage: ThumbnailCoverage, priority: DecodePriority) {
        start(id, edge: coverage.fallbackEdge, priority: priority)
    }
    func cancel(_ id: ItemID) { counts.cancels[id, default: 0] += 1; notify() }
    /// Returns once the condition holds; awaited on log changes, not polled.
    func until(_ condition: @escaping @Sendable (Counts) -> Bool) async -> Counts {
        if condition(counts) { return counts }
        return await withCheckedContinuation { waiters[UUID()] = (condition, $0) }
    }
    private func notify() {
        for (id, waiter) in waiters where waiter.condition(counts) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: counts)
        }
    }
}

/// Mirrors the App's grid observer: the session reconciles first, then the grid shows the session's selection.
@Test(.timeLimit(.minutes(2))) @MainActor
func watchedRefreshReconcilesMultiSelectionAndCancelsRemovedThumbnails() async throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-watch-refresh")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = ["A.jpg", "B.jpg", "C.jpg", "D.jpg"].map { FolderEntry(url: folder.appendingPathComponent($0), root: root) }
    let ids = entries.map(\.itemID)
    let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
    func snapshot(_ kept: [FolderEntry], generation: UInt64) -> FolderSnapshot {
        FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: generation), entries: kept, isComplete: true)
    }
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 640, height: 700))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    let log = WatchRefreshThumbnailLog()
    grid.thumbnailLoader = { entry, _, edge, priority in
        await log.start(entry.itemID, edge: edge, priority: priority)
        try? await Task.sleep(for: .seconds(600))
        await log.cancel(entry.itemID)
        throw CancellationError()
    }
    let session = ViewerSession(host: WatchRefreshHost())
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: a)
    session.select(b)
    session.select(d, modifier: .command)
    #expect(session.selection.selectedItemIDs == [b, d])
    #expect(session.selection.currentItemID == d)
    grid.display(snapshot(entries, generation: 1), selection: session.selection)
    // Settle window geometry and backing scale before the first request, so every cell is requested as visible.
    window.layoutIfNeeded()
    grid.layoutSubtreeIfNeeded()
    grid.setThumbnailsActive(true)
    _ = await log.until { counts in ids.allSatisfy { counts.live($0) == 1 } }
    // A headless window may finish sizing after requests begin. Exercise that transition
    // explicitly and take the refresh baseline only at the final tile edge.
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.layoutIfNeeded()
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
    let settledEdge = GridThumbnailPixelSizing.edge(tile: NSSize(width: layout.itemSize.width - 8,
        height: layout.itemSize.height - 36), backingScale: window.backingScaleFactor)
    let base = await log.until { counts in ids.allSatisfy {
        counts.live($0) == 1 && counts.edges[$0]?.last == settledEdge
    } }
    let edge = try #require(base.edges[a]?.last)
    #expect(ids.allSatisfy { base.edges[$0]?.last == edge })

    // R1: the selected Current Item is deleted. Current moves to its predecessor; the selection only shrinks.
    let first = snapshot(Array(entries.prefix(3)), generation: 2)
    session.updateItems(first.navigationEntries.map(\.itemID), sourceVersion: .init(2))
    grid.display(first, selection: session.selection)
    #expect(session.selection.selectedItemIDs == [b])
    #expect(session.selection.currentItemID == c)
    #expect(grid.selection == session.selection)
    #expect(grid.currentItemID == c)
    #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    // The removed item's request is cancelled and never restarted; each survivor restarts once for the new generation.
    let r1 = await log.until { counts in
        counts.live(d) == 0 && [a, b, c].allSatisfy { counts.live($0) == 1 && counts.added(since: base, $0) >= 1 }
    }
    #expect([a, b, c, d].map { r1.added(since: base, $0) } == [1, 1, 1, 0])

    // R2: a selected non-current item is deleted. Current stays; the selection empties without adopting Current.
    let second = snapshot([entries[0], entries[2]], generation: 3)
    session.updateItems(second.navigationEntries.map(\.itemID), sourceVersion: .init(3))
    grid.display(second, selection: session.selection)
    #expect(session.selection.selectedItemIDs.isEmpty)
    #expect(session.selection.currentItemID == c)
    #expect(grid.currentItemID == c)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)
    let r2 = await log.until { counts in
        counts.live(b) == 0 && [a, c].allSatisfy { counts.live($0) == 1 && counts.added(since: base, $0) >= 2 }
    }
    #expect([a, b, c, d].map { r2.added(since: base, $0) } == [2, 1, 2, 0])

    grid.stopThumbnails()
    let end = await log.until { counts in ids.allSatisfy { counts.live($0) == 0 } }
    // No late restart: totals are exactly the baseline plus the restarts above, all at the baseline edge, all visible.
    #expect(ids.map { end.added(since: base, $0) } == [2, 1, 2, 0])
    for id in ids {
        let skipped = base.starts[id, default: 0]
        #expect(end.edges[id, default: []].dropFirst(skipped).allSatisfy { $0 == edge })
        #expect(end.priorities[id, default: []].dropFirst(skipped).allSatisfy { $0 == .visible })
    }
    #expect(ids.allSatisfy { base.priorities[$0]?.last == .visible })
}
