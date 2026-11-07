import AppKit
import Testing
import MadoCore
@testable import MadoInfrastructure
@testable import MadoMacUI

/// What is left once both windows have closed; a round that leaks would change it.
private struct QuiescentState: Equatable {
    let entries: Int
    let cachedBytes: Int
    let usage: MemoryBudget.Usage
    let pendingLookups: Int
    let running: Int
    let waiting: Int
}

// #139 / plan §10 resource row: two windows on one pipeline, the same folder browsed three times.
// Measured with the ledger (instrumented), not with RSS.
@Test(.timeLimit(.minutes(2))) @MainActor func twoWindowsThreeRoundsStayWithinOneBudgetWithoutGrowth() async throws {
    let (folder, names) = try GridSharedBudgetTests.folder(copies: 16)
    defer { try? FileManager.default.removeItem(at: folder) }
    let rootID = AccessRootID(rawValue: UUID()), root = ItemIdentityRoot(id: rootID, url: folder)
    let snapshot = pinningSnapshot(count: names.count, folder: folder, rootID: rootID, names: names)
    let tile = ThumbnailCoverage(width: 16, height: 12)
    // One probe decode gives the real pixel bytes per thumbnail and the staging cost admission reserves for it.
    let probe = ImageIOPipeline()
    let probeRequest = try await probe.request(for: folder.appendingPathComponent(names[0]), covering: tile, identityRoot: root)
    let probeImage = try await probe.image(for: probeRequest).image
    let pixels = probeImage.bytesPerRow * probeImage.height
    let cost = try DecodeBudget.outputCost(width: 1280, height: 960, maximumPixelSize: probeRequest.maximumPixelSize,
                                           bytesPerPixel: 4, budget: .max)
    // A shows 0…3 and holds 0…5; B shows 8…11 and holds 6…13: 14 distinct pins, leaving one decode of room.
    let windows: [(visible: Set<Int>, held: ClosedRange<Int>)] = [([0, 1, 2, 3], 0...5), ([8, 9, 10, 11], 6...13)]
    let limit = 14 * pixels + cost
    let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit))
    let budget = try #require(pipeline.cache.budget)
    var rounds: [QuiescentState] = []
    var largestTotal = 0
    for round in 1...3 {
        let schedulers = windows.map { _ in GridThumbnailScheduler() }
        for (scheduler, window) in zip(schedulers, windows) {
            scheduler.pinning = pipeline
            scheduler.setSnapshot(snapshot)
            scheduler.reconcile(visible: window.visible, columns: 1, coverage: tile,
                                loader: GridSharedBudgetTests.loader(pipeline, root: root))
        }
        for (scheduler, window) in zip(schedulers, windows) {
            for index in window.held { await scheduler.waitForTerminal(at: index) }
            await scheduler.settlePins()
            for index in window.held { #expect(scheduler.result(at: index) != nil, "round \(round) item \(index)") }
        }
        largestTotal = max(largestTotal, budget.usage.total)
        #expect(budget.usage.pinned == 14 * pixels, "round \(round)")
        // Once the views hold their thumbnails and no decode is staged, the total is back within the limit.
        #expect(budget.usage.reserved == 0 && budget.usage.total <= limit, "round \(round)")
        for scheduler in schedulers { scheduler.stop(); await scheduler.settlePins() }
        let activity = await pipeline.admission.activity(), cache = await pipeline.cache.usage()
        rounds.append(QuiescentState(entries: cache.entries, cachedBytes: cache.totalBytes, usage: budget.usage,
            pendingLookups: await pipeline.cache.pendingCount(), running: activity.running, waiting: activity.waiting))
        largestTotal = max(largestTotal, budget.usage.total)
    }
    // Staging and evictable pixels only take room that is left. Pins are never refused, so a thumbnail pinned
    // after its own staging was released, while newer staging is outstanding, can overshoot by at most the pins
    // the windows hold (CACHE-01 limit).
    #expect(budget.peak <= limit + 14 * pixels)
    #expect(budget.peak >= largestTotal)
    #expect(rounds[0].usage.pinned == 0 && rounds[0].usage.reserved == 0)
    #expect(rounds[0].pendingLookups == 0 && rounds[0].running == 0 && rounds[0].waiting == 0)
    #expect(rounds[1] == rounds[0])
    #expect(rounds[2] == rounds[0])
}
