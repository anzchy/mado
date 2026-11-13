import AppKit
import Foundation
import Testing
import MadoCore
@testable import MadoMacUI

private func gridThumbnailSnapshot(rootID: AccessRootID, count: Int, generation: UInt64) -> FolderSnapshot {
    let folder = URL(fileURLWithPath: "/tmp/grid-thumbnail-s2")
    let root = ItemIdentityRoot(id: rootID, url: folder)
    return FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: generation),
        entries: (0..<count).map { FolderEntry(url: folder.appendingPathComponent(String(format: "%04d.jpg", $0)), root: root) },
        isComplete: true)
}

private actor HeldGridThumbnailPort {
    private(set) var started: Set<ItemID> = []
    private(set) var cancelled: Set<ItemID> = []
    private var startWaiters: [ItemID: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelWaiters: [ItemID: [CheckedContinuation<Void, Never>]] = [:]
    func waitStarted(_ id: ItemID) async {
        if started.contains(id) { return }
        await withCheckedContinuation { startWaiters[id, default: []].append($0) }
    }
    func waitCancelled(_ id: ItemID) async {
        if cancelled.contains(id) { return }
        await withCheckedContinuation { cancelWaiters[id, default: []].append($0) }
    }
    func load(_ entry: FolderEntry) async throws -> (ImageDecodeRequest, DecodedImage) {
        started.insert(entry.itemID)
        for waiter in startWaiters.removeValue(forKey: entry.itemID) ?? [] { waiter.resume() }
        do { try await Task.sleep(for: .seconds(60)) }
        catch {
            cancelled.insert(entry.itemID)
            for waiter in cancelWaiters.removeValue(forKey: entry.itemID) ?? [] { waiter.resume() }
            throw error
        }
        throw CancellationError()
    }
}

private actor GridAttemptCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private func gridThumbnailDecoded(_ entry: FolderEntry, edge: Int, revision: Int) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: revision, modificationDate: nil), maximumPixelSize: edge)
    let request = ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key)
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
        revision: key.revision, itemID: entry.itemID)
    return (request, image)
}

/// Pre-#161 call sites name only the edge; a square tile of half that edge has it as its fallback edge.
extension GridThumbnailScheduler {
    fileprivate func reconcile(visible: Set<Int>, columns: Int, pixelEdge: Int, loader: Loader?) {
        reconcile(visible: visible, columns: columns,
                  coverage: ThumbnailCoverage(width: Double(pixelEdge) / 2, height: Double(pixelEdge) / 2), loader: loader)
    }
}

private func gridThumbnailDecoded(_ entry: FolderEntry, edge coverage: ThumbnailCoverage, revision: Int) -> (ImageDecodeRequest, DecodedImage) {
    gridThumbnailDecoded(entry, edge: coverage.fallbackEdge, revision: revision)
}

private actor GridPriorityPort {
    private var seen: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private func key(_ id: ItemID, _ priority: DecodePriority) -> String { "\(id):\(priority)" }
    func load(_ id: ItemID, priority: DecodePriority) async throws -> (ImageDecodeRequest, DecodedImage) {
        let key = key(id, priority)
        seen.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func has(_ id: ItemID, priority: DecodePriority) -> Bool { seen.contains(key(id, priority)) }
    func waitFor(_ id: ItemID, priority: DecodePriority) async {
        let key = key(id, priority)
        if seen.contains(key) { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridThumbnailRapidScrollKeepsOnlyVisibleAndTwoNearbyRows() {
    let root = AccessRootID(rawValue: UUID())
    let snapshot = gridThumbnailSnapshot(rootID: root, count: 5000, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    let loader: GridThumbnailScheduler.Loader = { _, _, _, _ in throw CancellationError() }
    for visible in [Set(0..<12), Set(2400..<2412), Set(4988..<5000), Set(0..<12)] {
        scheduler.reconcile(visible: visible, columns: 4, pixelEdge: 424, loader: loader)
        let lower = max(0, visible.min()! - 8), upper = min(4999, visible.max()! + 8)
        let allowed = Set((lower...upper).map { snapshot.navigationEntries[$0].itemID })
        #expect(scheduler.activeItemIDs.isSubset(of: allowed))
        #expect(Set(visible.map { snapshot.navigationEntries[$0].itemID }).isSubset(of: scheduler.activeItemIDs))
        #expect(scheduler.activeItemIDs.count <= 28)
    }
    scheduler.stop()
    #expect(scheduler.activeItemIDs.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridThumbnailRootAndScaleReplacementRetireOldRequests() {
    let first = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 20, generation: 1)
    let second = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 20, generation: 2)
    let scheduler = GridThumbnailScheduler()
    let loader: GridThumbnailScheduler.Loader = { _, _, _, _ in throw CancellationError() }
    scheduler.setSnapshot(first)
    scheduler.reconcile(visible: [0, 1, 2], columns: 3, pixelEdge: 212, loader: loader)
    #expect(scheduler.activeItemIDs.contains(first.navigationEntries[0].itemID))
    scheduler.setSnapshot(second)
    #expect(scheduler.activeItemIDs.isEmpty)
    scheduler.reconcile(visible: [0, 1, 2], columns: 3, pixelEdge: 424, loader: loader)
    #expect(scheduler.activeItemIDs.contains(second.navigationEntries[0].itemID))
    #expect(!scheduler.activeItemIDs.contains(first.navigationEntries[0].itemID))
    scheduler.setSnapshot(nil)
    #expect(scheduler.activeItemIDs.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridSearchFilterCancelsOldThumbnailsAndStartsMatchingRequest() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 4, generation: 1)
    let first = snapshot.navigationEntries[0].itemID
    let match = snapshot.navigationEntries[3].itemID
    let port = HeldGridThumbnailPort()
    let scheduler = GridThumbnailScheduler()
    let loader: GridThumbnailScheduler.Loader = { entry, _, _, _ in try await port.load(entry) }

    scheduler.setSnapshot(snapshot)
    scheduler.reconcile(visible: [0, 3], columns: 1, pixelEdge: 424, loader: loader)
    await port.waitStarted(first)
    let oldMatchToken = scheduler.token(at: 3)
    #expect(oldMatchToken != nil)

    let filtered = snapshot.filteringFilename("0003")
    scheduler.setSnapshot(filtered)
    #expect(scheduler.activeItemIDs.isEmpty)
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await port.waitCancelled(first)
    await port.waitStarted(match)
    #expect(scheduler.activeItemIDs == [match])
    #expect(scheduler.token(at: 0) != oldMatchToken)
    scheduler.stop()
    await port.waitCancelled(match)
}

@Test(.timeLimit(.minutes(2))) func gridThumbnailPixelSizingRoundsUpForRetina() {
    #expect(GridThumbnailPixelSizing.edge(tile: NSSize(width: 212, height: 148), backingScale: 1) >= 318)
    #expect(GridThumbnailPixelSizing.edge(tile: NSSize(width: 212, height: 148), backingScale: 2) >= 636)
    #expect(GridThumbnailPixelSizing.edge(tile: NSSize(width: 211.5, height: 148), backingScale: 2) >= 635)
    #expect(GridThumbnailPixelSizing.edge(tile: NSSize(width: 212, height: 148), backingScale: 2) == 848)
    let coverEdge = GridThumbnailPixelSizing.edge(tile: NSSize(width: 212, height: 148), backingScale: 2)
    #expect(Double(coverEdge) * 2 / 3 >= 212 * 2) // 2:3 portrait's short side fills the tile width.
    #expect(Double(coverEdge) * 2 / 3 >= 148 * 2) // 3:2 landscape's short side fills the tile height.
    #expect(GridThumbnailPixelSizing.edge(tile: NSSize(width: 900, height: 700), backingScale: 2) == 1024)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridFailedPrefetchReplaysAndRetriesOnlyOnVisibilityTransition() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 4, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    var failures: [Int] = []
    scheduler.onFailure = { failures.append($0) }
    // A real failure; a prefetch the pipeline refuses under pressure is deferred instead (#139).
    let loader: GridThumbnailScheduler.Loader = { _, _, _, _ in throw ImageLoadError(.corruptImage) }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await scheduler.waitForTerminal(at: 2)
    #expect(scheduler.hasFailure(at: 2))
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    #expect(scheduler.hasFailure(at: 2))
    scheduler.reconcile(visible: [2], columns: 1, pixelEdge: 424, loader: loader)
    #expect(!scheduler.hasFailure(at: 2))
    await scheduler.waitForTerminal(at: 2)
    #expect(scheduler.hasFailure(at: 2))
    #expect(failures.contains(2))
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridSourceChangedRetriesOnceWithFreshRequest() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 1, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    let attempts = GridAttemptCounter()
    let loader: GridThumbnailScheduler.Loader = { entry, _, edge, _ in
        let count = await attempts.next()
        if count == 1 { throw ImageLoadError(.sourceChanged) }
        return gridThumbnailDecoded(entry, edge: edge, revision: count)
    }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await scheduler.waitForTerminal(at: 0)
    #expect(await attempts.count == 2)
    #expect(scheduler.result(at: 0)?.0.renderKey?.revision.byteCount == 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridAdmissionRejectionRecoversWhenCapacityFrees() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 3, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    let rejectedID = snapshot.navigationEntries[2].itemID
    let loader: GridThumbnailScheduler.Loader = { entry, _, edge, priority in
        if entry.itemID == rejectedID && priority == .prefetch {
            throw ImageLoadError(.cancelled)
        }
        return gridThumbnailDecoded(entry, edge: edge, revision: 9)
    }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await scheduler.waitForTerminal(at: 2)
    // A refused prefetch is deferred, not shown as a failure (#139).
    #expect(!scheduler.hasFailure(at: 2) && !scheduler.shouldDisplayFailure(at: 2))
    #expect(scheduler.result(at: 2) == nil)
    scheduler.reconcile(visible: [2], columns: 1, pixelEdge: 424, loader: loader)
    await scheduler.waitForTerminal(at: 2)
    #expect(!scheduler.hasFailure(at: 2))
    #expect(scheduler.result(at: 2)?.0.renderKey?.revision.byteCount == 9)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridFailedVisibleRequestRetriesAfterNearbyRevisit() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 3, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    let attempts = GridAttemptCounter()
    let failedID = snapshot.navigationEntries[0].itemID
    let loader: GridThumbnailScheduler.Loader = { entry, _, edge, _ in
        if entry.itemID == failedID {
            let count = await attempts.next()
            if count == 1 { throw ImageLoadError(.corruptImage) }
            return gridThumbnailDecoded(entry, edge: edge, revision: count)
        }
        return gridThumbnailDecoded(entry, edge: edge, revision: 1)
    }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await scheduler.waitForTerminal(at: 0)
    #expect(scheduler.hasFailure(at: 0))
    scheduler.reconcile(visible: [1], columns: 1, pixelEdge: 424, loader: loader)
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await scheduler.waitForTerminal(at: 0)
    #expect(scheduler.result(at: 0) != nil)
    #expect(await attempts.count == 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridPendingPrefetchPromotesWhenVisible() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 3, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    let port = GridPriorityPort()
    let loader: GridThumbnailScheduler.Loader = { entry, _, _, priority in
        try await port.load(entry.itemID, priority: priority)
    }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 424, loader: loader)
    await port.waitFor(snapshot.navigationEntries[2].itemID, priority: .prefetch)
    scheduler.reconcile(visible: [2], columns: 1, pixelEdge: 424, loader: loader)
    await port.waitFor(snapshot.navigationEntries[2].itemID, priority: .visible)
    #expect(await port.has(snapshot.navigationEntries[2].itemID, priority: .visible))
    scheduler.stop()
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridThumbnailScrollAndCloseCancelHeldFilePortWork() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 30, generation: 1)
    let port = HeldGridThumbnailPort()
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    let loader: GridThumbnailScheduler.Loader = { entry, _, _, _ in try await port.load(entry) }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 212, loader: loader)
    let first = snapshot.navigationEntries[0].itemID
    await port.waitStarted(first)
    #expect(await port.started.contains(first))
    scheduler.reconcile(visible: [20], columns: 1, pixelEdge: 212, loader: loader)
    await port.waitCancelled(first)
    #expect(await port.cancelled.contains(first))
    let later = snapshot.navigationEntries[20].itemID
    await port.waitStarted(later)
    scheduler.stop()
    await port.waitCancelled(later)
    #expect(await port.cancelled.contains(later))
    #expect(scheduler.activeItemIDs.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridThumbnailInvalidDecodedIdentityShowsFailureInsteadOfPendingForever() async {
    let snapshot = gridThumbnailSnapshot(rootID: AccessRootID(rawValue: UUID()), count: 1, generation: 1)
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    var failed = false
    scheduler.onFailure = { _ in failed = true }
    let loader: GridThumbnailScheduler.Loader = { entry, _, coverage, _ in
        let edge = coverage.fallbackEdge
        let key = RenderKey(itemID: entry.itemID,
            revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: edge)
        let request = ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key)
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: key.revision, itemID: .ephemeral(UUID()))
        return (request, image)
    }
    scheduler.reconcile(visible: [0], columns: 1, pixelEdge: 212, loader: loader)
    await scheduler.waitForTerminal(at: 0)
    #expect(failed)
    #expect(scheduler.result(at: 0) == nil)
}
