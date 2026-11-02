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

/// One pending record at index 0: its load has started and is held.
@MainActor private func i392Pending() async throws -> (GridThumbnailScheduler, I392Loader, FolderEntry, UUID) {
    let snapshot = i392Snapshot(count: 1), scheduler = GridThumbnailScheduler(), loader = I392Loader()
    let entry = snapshot.navigationEntries[0]
    scheduler.setSnapshot(snapshot)
    scheduler.reconcile(visible: [0], columns: 1, coverage: i392Tile) { entry, _, coverage, _ in
        try await loader.load(entry, coverage)
    }
    try await waitUntil { await loader.isStarted(entry.itemID) }
    return (scheduler, loader, entry, try #require(scheduler.token(at: 0)))
}

/// Without the fix a cancelled waiter would wait forever; this frees it after 5 s, so it returns into a stopped
/// scheduler (no token) and the expectations fail instead of the run hanging.
@MainActor private func i392Fallback(_ scheduler: GridThumbnailScheduler) -> Task<Void, Never> {
    Task { @MainActor in
        guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
        scheduler.stop()
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func i392PreCancelledTerminalWaitReturnsWhileRecordStaysPending() async throws {
    let (scheduler, loader, entry, token) = try await i392Pending()
    defer { scheduler.stop() }
    let seen = I392Observation()
    let waiter = i392Waiter(scheduler, at: 0, item: entry.itemID, seen)
    waiter.cancel() // before the waiter task first runs: it calls waitForTerminal already cancelled
    let fallback = i392Fallback(scheduler)
    await waiter.value
    fallback.cancel()
    #expect(seen.returns == 1)
    // Stopped by the fallback, the record is gone and a later wait would never end: stop here.
    try #require(seen.token == token, "the record is still the pending one")
    #expect(!seen.hasResult && !seen.hasFailure && !seen.displaysFailure)
    #expect(seen.itemActive)
    // Nothing of the cancelled call is left registered: the record still finishes once for a later waiter.
    await loader.release(entry.itemID)
    let later = I392Observation()
    await i392Waiter(scheduler, at: 0, item: entry.itemID, later).value
    #expect(later.returns == 1 && later.hasResult && later.token == token)
}
