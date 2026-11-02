import AppKit
import Foundation
import Testing
import PicseeCore
@testable import PicseeMacUI

// #392: a cancelled `waitForTerminal` returns at once and leaves its record and every other waiter as they were.

private let i392Tile = ThumbnailCoverage(width: 32, height: 32)

private func i392Snapshot(count: Int) -> FolderSnapshot {
    let folder = URL(fileURLWithPath: "/tmp/grid-terminal-wait-392")
    let rootID = AccessRootID(), root = ItemIdentityRoot(id: rootID, url: folder)
    return FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: (0..<count).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) },
        isComplete: true)
}

private func i392Decoded(_ entry: FolderEntry, edge: Int) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 1, modificationDate: nil),
        maximumPixelSize: edge)
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return (ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key),
        DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: key.revision, itemID: entry.itemID))
}

/// Holds each load until `release`, then returns a matching thumbnail; a cancelled load ends with the cancellation.
private actor I392Loader {
    private var started: Set<ItemID> = []
    private var released: Set<ItemID> = []
    private var held: [ItemID: CheckedContinuation<Void, Never>] = [:]
    func isStarted(_ id: ItemID) -> Bool { started.contains(id) }
    func release(_ id: ItemID) { released.insert(id); held.removeValue(forKey: id)?.resume() }
    func load(_ entry: FolderEntry, _ coverage: ThumbnailCoverage) async throws -> (ImageDecodeRequest, DecodedImage) {
        started.insert(entry.itemID)
        if !released.contains(entry.itemID) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { held[entry.itemID] = $0 }
            } onCancel: { Task { await self.release(entry.itemID) } }
        }
        try Task.checkCancellation()
        return i392Decoded(entry, edge: coverage.fallbackEdge)
    }
}

/// What a waiter saw on the main actor the moment `waitForTerminal` returned, before any other suspension.
@MainActor private final class I392Observation {
    var registering = false, returns = 0
    var token: UUID?, hasResult = false, hasFailure = false, displaysFailure = false, itemActive = false
}

@MainActor private func i392Waiter(_ scheduler: GridThumbnailScheduler, at index: Int, item: ItemID?,
                                   _ seen: I392Observation) -> Task<Void, Never> {
    Task { @MainActor in
        seen.registering = true
        await scheduler.waitForTerminal(at: index)
        seen.returns += 1
        seen.token = scheduler.token(at: index)
        seen.hasResult = scheduler.result(at: index) != nil
        seen.hasFailure = scheduler.hasFailure(at: index)
        seen.displaysFailure = scheduler.shouldDisplayFailure(at: index)
        seen.itemActive = item.map { scheduler.activeItemIDs.contains($0) } ?? false
    }
}

/// Gives `scheduler` one pending record at index 0: its load has started and is held.
@MainActor private func i392Arm(_ scheduler: GridThumbnailScheduler) async throws -> (I392Loader, FolderEntry, UUID) {
    let snapshot = i392Snapshot(count: 1), loader = I392Loader()
    let entry = snapshot.navigationEntries[0]
    scheduler.setSnapshot(snapshot)
    scheduler.reconcile(visible: [0], columns: 1, coverage: i392Tile) { entry, _, coverage, _ in
        try await loader.load(entry, coverage)
    }
    try await waitUntil { await loader.isStarted(entry.itemID) }
    return (loader, entry, try #require(scheduler.token(at: 0)))
}

@MainActor private func i392Pending() async throws -> (GridThumbnailScheduler, I392Loader, FolderEntry, UUID) {
    let scheduler = GridThumbnailScheduler()
    let (loader, entry, token) = try await i392Arm(scheduler)
    return (scheduler, loader, entry, token)
}

/// Runs `body` on a pending record; on every exit, an early `#require` included, stops the scheduler and awaits each
/// waiter the body tracked, so no freed waiter runs on into the next test (#398).
@MainActor private func i392WithPending(
    _ body: (GridThumbnailScheduler, I392Loader, FolderEntry, UUID, StartedTasks) async throws -> Void
) async throws {
    let (scheduler, loader, entry, token) = try await i392Pending()
    let started = StartedTasks()
    try await withAsyncTeardown { try await body(scheduler, loader, entry, token, started) } teardown: {
        await started.awaitAll { scheduler.stop() }
    }
}

/// Awaits a cancelled waiter. Without the fix it would wait forever: when the test's time limit cancels the test, this
/// stops the scheduler, so the waiter returns into a stopped scheduler (no token) and the expectations fail instead of
/// the run hanging. Cancellation, not a wall clock, drives it, so a stalled main actor cannot fire it (#390).
@MainActor private func i392Await(_ waiter: Task<Void, Never>, freeing scheduler: GridThumbnailScheduler) async {
    await withTaskCancellationHandler { await waiter.value } onCancel: { Task { @MainActor in scheduler.stop() } }
}

@Test(.timeLimit(.minutes(2))) @MainActor func i392PreCancelledTerminalWaitReturnsWhileRecordStaysPending() async throws {
    try await i392WithPending { scheduler, loader, entry, token, started in
        let seen = I392Observation()
        let waiter = started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, seen))
        waiter.cancel() // before the waiter task first runs: it calls waitForTerminal already cancelled
        await i392Await(waiter, freeing: scheduler)
        #expect(seen.returns == 1)
        // Freed by a stop, the record is gone and a later wait would never end: stop here.
        try #require(seen.token == token, "the record is still the pending one")
        #expect(!seen.hasResult && !seen.hasFailure && !seen.displaysFailure)
        #expect(seen.itemActive)
        // Nothing of the cancelled call is left registered: the record still finishes once for a later waiter.
        await loader.release(entry.itemID)
        let later = I392Observation()
        await i392Waiter(scheduler, at: 0, item: entry.itemID, later).value
        #expect(later.returns == 1 && later.hasResult && later.token == token)
    }
}

/// A and B wait on the same pending record; cancelling A returns only A, and B still sees the result.
@MainActor private func i392CancelOneOfTwo(offMain: Bool) async throws {
    try await i392WithPending { scheduler, loader, entry, token, started in
        let a = I392Observation(), b = I392Observation()
        let waiterA = started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, a))
        let waiterB = started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, b))
        try await waitUntil { a.registering && b.registering }
        if offMain { await Task.detached { waiterA.cancel() }.value } else { waiterA.cancel() }
        await i392Await(waiterA, freeing: scheduler)
        #expect(a.returns == 1)
        try #require(a.token == token, "A returned on its own cancel, not on a stop")
        #expect(!a.hasResult && !a.hasFailure && !a.displaysFailure && a.itemActive)
        #expect(b.returns == 0, "cancelling A does not return B")
        await loader.release(entry.itemID)
        await waiterB.value
        #expect(b.returns == 1 && b.hasResult && b.token == token)
        #expect(a.returns == 1, "A is not resumed again when the record finishes")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func i392CancelledTerminalWaiterReturnsWhileSiblingWaitsForResult() async throws {
    try await i392CancelOneOfTwo(offMain: false)
}

@Test(.timeLimit(.minutes(2))) @MainActor func i392WaiterCancelledFromOffMainReturnsWhileRecordStaysPending() async throws {
    try await i392CancelOneOfTwo(offMain: true)
}

/// Cancel and stop both reach a waiter in the same main-actor turn: it returns once, and the late cancel finds nothing.
@Test(.timeLimit(.minutes(2))) @MainActor func i392CancelLosingToStopResumesWaiterExactlyOnce() async throws {
    try await i392WithPending { scheduler, _, entry, _, started in
        let a = I392Observation()
        let waiterA = started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, a))
        try await waitUntil { a.registering }
        waiterA.cancel(); scheduler.stop()
        await waiterA.value
        #expect(a.returns == 1 && a.token == nil, "stop() ended the wait")
        for _ in 0..<5 { await Task.yield() }
        await Task { @MainActor in }.value
        scheduler.stop()
        // The scheduler still serves a new record and a new waiter after the stale cancel.
        let (loader, next, token) = try await i392Arm(scheduler)
        let c = I392Observation()
        let waiterC = started.track(i392Waiter(scheduler, at: 0, item: next.itemID, c))
        try await waitUntil { c.registering }
        await loader.release(next.itemID)
        await waiterC.value
        #expect(c.returns == 1 && c.hasResult && c.token == token)
        #expect(a.returns == 1)
    }
}

/// Every subset of three waiters on one pending record: the cancelled ones return with the record still pending,
/// the others return only with its result, and each returns once.
@Test(.timeLimit(.minutes(2)), arguments: 0..<8) @MainActor
func i392CancelledSubsetOfWaitersReturnsAndRestSeeResult(mask: Int) async throws {
    try await i392WithPending { scheduler, loader, entry, token, started in
        let seen = (0..<3).map { _ in I392Observation() }
        let waiters = seen.map { started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, $0)) }
        try await waitUntil { seen.allSatisfy(\.registering) }
        let cancelled = (0..<3).filter { mask & (1 << $0) != 0 }, kept = (0..<3).filter { mask & (1 << $0) == 0 }
        for k in cancelled { waiters[k].cancel(); await i392Await(waiters[k], freeing: scheduler) }
        for k in cancelled {
            #expect(seen[k].returns == 1, "mask=\(mask) waiter \(k)")
            try #require(seen[k].token == token, "mask=\(mask) waiter \(k) returned on its own cancel")
            #expect(!seen[k].hasResult && !seen[k].hasFailure, "mask=\(mask) waiter \(k)")
        }
        #expect(kept.allSatisfy { seen[$0].returns == 0 }, "mask=\(mask): only the cancelled waiters returned")
        await loader.release(entry.itemID)
        for k in kept {
            await waiters[k].value
            #expect(seen[k].returns == 1 && seen[k].hasResult && seen[k].token == token, "mask=\(mask) waiter \(k)")
        }
        #expect(cancelled.allSatisfy { seen[$0].returns == 1 }, "mask=\(mask): no cancelled waiter returned twice")
    }
}

/// A cancelled wait on an index with no record returns, and the pending record at index 0 is untouched.
@Test(.timeLimit(.minutes(2))) @MainActor func i392CancelledWaiterOnIndexWithoutRecordReturns() async throws {
    try await i392WithPending { scheduler, loader, entry, token, started in
        let x = I392Observation()
        let waiterX = started.track(i392Waiter(scheduler, at: 7, item: nil, x))
        try await waitUntil { x.registering }
        waiterX.cancel()
        await i392Await(waiterX, freeing: scheduler)
        #expect(x.returns == 1 && x.token == nil)
        try #require(scheduler.token(at: 0) == token, "X returned on its own cancel, not on a stop")
        await loader.release(entry.itemID)
        await scheduler.waitForTerminal(at: 0)
        #expect(scheduler.result(at: 0) != nil)
    }
}

private struct I398EarlyExit: Error {}

/// #398: a body that stops early (a failed `#require` throws the same way) still has its freed waiter awaited before
/// the helper returns, so the waiter's tail cannot run on into the next test.
@Test(.timeLimit(.minutes(2))) @MainActor func i398EarlyExitAwaitsTheFreedWaiters() async throws {
    let kept = I392Observation()
    do {
        try await i392WithPending { scheduler, _, entry, _, started in
            started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, kept))
            try await waitUntil { kept.registering }
            throw I398EarlyExit()
        }
        Issue.record("the body's early exit was swallowed")
    } catch is I398EarlyExit {}
    #expect(kept.returns == 1, "teardown awaited the waiter it freed")
    #expect(kept.token == nil, "the waiter returned on the teardown's stop")
}

/// #398: a body that returns normally with two waiters still pending has both freed by a stop and awaited.
@Test(.timeLimit(.minutes(2))) @MainActor func i398NormalReturnAwaitsEveryPendingWaiter() async throws {
    let seen = [I392Observation(), I392Observation()]
    try await i392WithPending { scheduler, _, entry, _, started in
        for observation in seen { started.track(i392Waiter(scheduler, at: 0, item: entry.itemID, observation)) }
        try await waitUntil { seen.allSatisfy(\.registering) }
    }
    #expect(seen.allSatisfy { $0.returns == 1 }, "teardown awaited both waiters")
    #expect(seen.allSatisfy { $0.token == nil }, "both returned on the teardown's stop, not on a cancel")
}
