import AppKit
import Testing
import MadoCore
@testable import MadoInfrastructure
@testable import MadoMacUI

/// Counts loader calls per item and priority; each item's outcome is chosen by the test.
private actor PressureLoaderLog {
    private(set) var calls: [ItemID: [DecodePriority]] = [:]
    private var waiters: [(condition: @Sendable ([ItemID: [DecodePriority]]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    func record(_ id: ItemID, _ priority: DecodePriority) {
        calls[id, default: []].append(priority)
        let ready = waiters.indices.filter { waiters[$0].condition(calls) }
        for index in ready.reversed() { waiters.remove(at: index).continuation.resume() }
    }
    func until(_ condition: @escaping @Sendable ([ItemID: [DecodePriority]]) -> Bool) async {
        if condition(calls) { return }
        await withCheckedContinuation { waiters.append((condition, $0)) }
    }
    var priorities: Set<DecodePriority> { Set(calls.values.flatMap { $0 }) }
}

private func pressureDecoded(_ entry: FolderEntry, coverage: ThumbnailCoverage) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 4, modificationDate: nil),
                        maximumPixelSize: coverage.fallbackEdge)
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return (ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: key.maximumPixelSize, renderKey: key),
            DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1), revision: key.revision, itemID: entry.itemID))
}

private let pressureTile = ThumbnailCoverage(width: 212, height: 212)

@Suite(.timeLimit(.minutes(2))) @MainActor struct GridThumbnailPressureTests {
    // 4.1, 4.2: pressure keeps only visible cells; held prefetched results are released, visible ones stay.
    @Test func pressureDropsPrefetchedResultsAndRequestsOnlyVisibleCells() async throws {
        let snapshot = pinningSnapshot(count: 20), fake = RecordingPinning(), log = PressureLoaderLog()
        let ids = snapshot.navigationEntries.map(\.itemID)
        let scheduler = GridThumbnailScheduler()
        scheduler.pinning = fake
        scheduler.setSnapshot(snapshot)
        let loader: GridThumbnailScheduler.Loader = { entry, _, coverage, priority in
            await log.record(entry.itemID, priority)
            return pressureDecoded(entry, coverage: coverage)
        }
        scheduler.reconcile(visible: [5], columns: 1, coverage: pressureTile, loader: loader)
        for index in 3...7 { await scheduler.waitForTerminal(at: index) }
        await scheduler.settlePins()
        #expect(await fake.held == 5)
        scheduler.setMemoryPressure(true)
        scheduler.reconcile(visible: [5], columns: 1, coverage: pressureTile, loader: loader)
        await scheduler.settlePins()
        #expect(scheduler.activeItemIDs == [ids[5]])
        #expect(scheduler.result(at: 5) != nil)
        #expect(await fake.held == 1)
        scheduler.reconcile(visible: [10, 11], columns: 1, coverage: pressureTile, loader: loader)
        for index in 10...11 { await scheduler.waitForTerminal(at: index) }
        #expect(scheduler.activeItemIDs == [ids[10], ids[11]])
        let underPressure = await log.calls
        #expect(underPressure[ids[9]] == nil && underPressure[ids[12]] == nil)
        #expect(await log.calls[ids[10]] == [.visible])
        scheduler.setMemoryPressure(false)
        scheduler.reconcile(visible: [10, 11], columns: 1, coverage: pressureTile, loader: loader)
        await log.until { $0[ids[13]] == [.prefetch] && $0[ids[8]] == [.prefetch] }
        scheduler.stop()
    }

    // 4.3, 4.3c, 4.5: a prefetch the pipeline refuses is deferred, not failed, and only the next reconcile retries it.
    @Test func refusedPrefetchIsDeferredUntilTheNextReconcile() async throws {
        let snapshot = pinningSnapshot(count: 5), log = PressureLoaderLog()
        let ids = snapshot.navigationEntries.map(\.itemID)
        let refusing = Refusal()
        let scheduler = GridThumbnailScheduler()
        scheduler.setSnapshot(snapshot)
        var failures: [Int] = []
        scheduler.onFailure = { failures.append($0) }
        let loader: GridThumbnailScheduler.Loader = { entry, _, coverage, priority in
            await log.record(entry.itemID, priority)
            if await refusing.on { throw ImageLoadError(.cancelled, itemID: entry.itemID) }
            return pressureDecoded(entry, coverage: coverage)
        }
        await refusing.set(true)
        scheduler.reconcile(visible: [0], columns: 1, coverage: pressureTile, loader: loader)
        for index in 0...2 { await scheduler.waitForTerminal(at: index) }
        #expect(failures == [0])
        #expect(scheduler.shouldDisplayFailure(at: 0))
        for index in 1...2 {
            #expect(!scheduler.shouldDisplayFailure(at: index))
            #expect(scheduler.result(at: index) == nil)
        }
        #expect(scheduler.activeItemIDs == [ids[0]])
        #expect(await log.calls[ids[1]] == [.prefetch])
        await refusing.set(false)
        scheduler.reconcile(visible: [0], columns: 1, coverage: pressureTile, loader: loader)
        for index in 1...2 { await scheduler.waitForTerminal(at: index) }
        #expect(scheduler.result(at: 1) != nil && scheduler.result(at: 2) != nil)
        #expect(await log.calls[ids[1]] == [.prefetch, .prefetch])
        #expect(failures == [0])
        scheduler.stop()
    }

    // 4.3b: a real prefetch failure still shows and is not retried while the cell stays off screen.
    @Test func failedPrefetchStillFailsAndIsNotRetriedOffScreen() async throws {
        let snapshot = pinningSnapshot(count: 3), log = PressureLoaderLog()
        let ids = snapshot.navigationEntries.map(\.itemID)
        let scheduler = GridThumbnailScheduler()
        scheduler.setSnapshot(snapshot)
        var failures: [Int] = []
        scheduler.onFailure = { failures.append($0) }
        let loader: GridThumbnailScheduler.Loader = { entry, _, coverage, priority in
            await log.record(entry.itemID, priority)
            if entry.itemID == ids[2] { throw ImageLoadError(.corruptImage, itemID: entry.itemID) }
            return pressureDecoded(entry, coverage: coverage)
        }
        scheduler.reconcile(visible: [0], columns: 1, coverage: pressureTile, loader: loader)
        for index in 0...2 { await scheduler.waitForTerminal(at: index) }
        #expect(failures == [2])
        #expect(scheduler.shouldDisplayFailure(at: 2))
        scheduler.reconcile(visible: [0], columns: 1, coverage: pressureTile, loader: loader)
        #expect(await log.calls[ids[2]] == [.prefetch])
        scheduler.stop()
    }

    // 4.4: the view drops margin rows under pressure and requests them again as soon as it ends, without a scroll.
    @Test func gridViewResumesPrefetchWhenPressureEnds() async throws {
        _ = NSApplication.shared
        let snapshot = pinningSnapshot(count: 200), log = PressureLoaderLog()
        let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
        let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid
        grid.thumbnailLoader = { entry, _, coverage, priority in
            await log.record(entry.itemID, priority)
            return pressureDecoded(entry, coverage: coverage)
        }
        grid.display(snapshot, selectedItemID: nil)
        window.layoutIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.setMemoryPressure(true)
        grid.setThumbnailsActive(true)
        await grid.waitForThumbnail(at: 0)
        #expect(await log.priorities == [.visible])
        grid.setMemoryPressure(false)
        await log.until { $0.values.contains { $0.contains(.prefetch) } }
        grid.stopThumbnails()
    }
}

private actor Refusal {
    private(set) var on = false
    func set(_ value: Bool) { on = value }
}

/// A pressure clock that moves only when the test advances it; each sleep wakes once the clock reaches its end.
final class ManualPressureTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var sleepers: [(id: UUID, until: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []
    private var asked: [TimeInterval] = []
    var now: TimeInterval { lock.withLock { current } }
    var requested: [TimeInterval] { lock.withLock { asked } }
    var sleeping: Int { lock.withLock { sleepers.count } }
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    asked.append(seconds)
                    if Task.isCancelled { return true }
                    sleepers.append((id, current + seconds, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index).continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }
    func advance(by seconds: TimeInterval) {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current += seconds
            let due = sleepers.filter { $0.until <= current }
            sleepers.removeAll { $0.until <= current }
            return due.map(\.continuation)
        }
        for sleeper in woken { sleeper.resume() }
    }
    /// True once `count` sleeps are pending; throws when the bounded wait ends first (#392).
    func waitForSleepers(_ count: Int) async throws -> Bool {
        try await waitUntil { sleeping == count }
        return sleeping == count
    }
}

/// Counts the scheduler's waits and forwards them to the pipeline.
private actor CountingResumption: PrefetchResuming {
    let base: any PrefetchResuming
    private(set) var calls = 0
    init(base: any PrefetchResuming) { self.base = base }
    func prefetchResumes() async { calls += 1; await base.prefetchResumes() }
}

/// Holds each wait until `release()`; like the pipeline, a cancelled wait returns normally.
actor GatedResumption: PrefetchResuming {
    private(set) var calls = 0
    private(set) var returned = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func prefetchResumes() async {
        calls += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: { Task { await self.release() } }
        returned += 1
    }
    func release() { waiter?.resume(); waiter = nil }
}

/// Bounded like `waitUntil`: throws when the wait ends before the condition holds (#392).
@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws -> Bool {
    try await waitUntil { await condition() }
    return await condition()
}

/// Real pipeline and its pressure clock: the scheduler waits for the pipeline's recovery delay, not for a scroll (#139 R1).
@Suite(.timeLimit(.minutes(2))) @MainActor struct GridPrefetchResumptionTests {
    // R1 1.1, 1.2, 1.4b: refused margin cells are asked once, kept through reconciles and scrolls inside the recovery
    // window (a deferred cell that becomes visible is asked as visible), and requested once more when the delay ends.
    @Test func deferredPrefetchWaitsForThePipelineAndResumesWithoutAScroll() async throws {
        let (folder, names) = try GridSharedBudgetTests.folder(copies: 10)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rootID = AccessRootID(rawValue: UUID()), root = ItemIdentityRoot(id: rootID, url: folder)
        let snapshot = pinningSnapshot(count: names.count, folder: folder, rootID: rootID, names: names)
        let ids = snapshot.navigationEntries.map(\.itemID)
        let time = ManualPressureTime()
        let pipeline = ImageIOPipeline(pressureClock: { time.now }, pressureSleep: { try await time.sleep($0) })
        let budget = try #require(pipeline.cache.budget)
        let resumption = CountingResumption(base: pipeline), log = PressureLoaderLog()
        let scheduler = GridThumbnailScheduler()
        scheduler.pinning = pipeline
        scheduler.prefetchResumption = resumption
        scheduler.setSnapshot(snapshot)
        var failures: [Int] = []
        scheduler.onFailure = { failures.append($0) }
        let real = GridSharedBudgetTests.loader(pipeline, root: root)
        let loader: GridThumbnailScheduler.Loader = { entry, rootID, coverage, priority in
            await log.record(entry.itemID, priority)
            return try await real(entry, rootID, coverage, priority)
        }
        let tile = ThumbnailCoverage(width: 16, height: 12)
        func reconcile(_ visible: Set<Int>) { scheduler.reconcile(visible: visible, columns: 1, coverage: tile, loader: loader) }

        await pipeline.memoryPressure(.warning)
        await pipeline.memoryPressure(.normal)
        reconcile([0])
        for index in 0...2 { await scheduler.waitForTerminal(at: index) }
        #expect(scheduler.result(at: 0) != nil)
        #expect(scheduler.result(at: 1) == nil && scheduler.result(at: 2) == nil)
        #expect(try await time.waitForSleepers(1))
        for _ in 0..<3 { reconcile([0]) }
        reconcile([2])
        await scheduler.waitForTerminal(at: 2)
        reconcile([3])
        await scheduler.waitForTerminal(at: 3)
        let window = await log.calls
        #expect(window[ids[0]] == [.visible])
        #expect(window[ids[1]] == [.prefetch])
        #expect(window[ids[2]] == [.prefetch, .visible])
        #expect(window[ids[3]] == [.visible])
        #expect(window[ids[4]] == nil && window[ids[5]] == nil)
        #expect(failures.isEmpty)
        #expect(await resumption.calls == 1)

        time.advance(by: 5)
        #expect(try await eventually { (1...5).allSatisfy { scheduler.result(at: $0) != nil } })
        let resumed = await log.calls
        #expect(resumed[ids[0]] == [.visible])
        #expect(resumed[ids[1]] == [.prefetch, .prefetch])
        #expect(resumed[ids[2]] == [.prefetch, .visible])
        #expect(resumed[ids[3]] == [.visible])
        #expect(resumed[ids[4]] == [.prefetch] && resumed[ids[5]] == [.prefetch])
        #expect(resumed[ids[6]] == nil)
        #expect(failures.isEmpty)
        await scheduler.settlePins()
        let held = (1...5).compactMap { scheduler.result(at: $0)?.1.image }.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        #expect(budget.usage.pinned == held)

        // A second pressure episode defers the margin again and resumes it the same way.
        await pipeline.memoryPressure(.warning)
        scheduler.setMemoryPressure(true)
        reconcile([3])
        await pipeline.memoryPressure(.normal)
        scheduler.setMemoryPressure(false)
        reconcile([3])
        for index in 1...5 { await scheduler.waitForTerminal(at: index) }
        #expect(try await time.waitForSleepers(1))
        #expect(await resumption.calls == 2)
        #expect(scheduler.result(at: 1) == nil && scheduler.result(at: 5) == nil)
        time.advance(by: 5)
        #expect(try await eventually { [1, 2, 4, 5].allSatisfy { scheduler.result(at: $0) != nil } })
        #expect(await log.calls[ids[1]] == [.prefetch, .prefetch, .prefetch, .prefetch])
        #expect(failures.isEmpty)
        scheduler.stop()
        await scheduler.settlePins()
        #expect(budget.usage.pinned == 0)
    }

    // R1 1.3: a folder change while waiting cancels the wait; nothing is asked when the wait returns.
    @Test func folderChangeCancelsThePrefetchWait() async throws {
        let log = PressureLoaderLog(), refusing = Refusal(), gate = GatedResumption()
        let scheduler = GridThumbnailScheduler()
        scheduler.prefetchResumption = gate
        scheduler.setSnapshot(pinningSnapshot(count: 5))
        let loader: GridThumbnailScheduler.Loader = { entry, _, coverage, priority in
            await log.record(entry.itemID, priority)
            if priority == .prefetch, await refusing.on { throw ImageLoadError(.cancelled, itemID: entry.itemID) }
            return pressureDecoded(entry, coverage: coverage)
        }
        await refusing.set(true)
        scheduler.reconcile(visible: [0], columns: 1, coverage: pressureTile, loader: loader)
        for index in 0...2 { await scheduler.waitForTerminal(at: index) }
        #expect(try await eventually { await gate.calls == 1 })
        scheduler.setSnapshot(pinningSnapshot(count: 5))
        #expect(try await eventually { await gate.returned == 1 })
        await refusing.set(false)
        for _ in 0..<50 { await Task.yield() }
        #expect(scheduler.token(at: 0) == nil)
        #expect(await log.calls.values.reduce(0) { $0 + $1.count } == 3)
        scheduler.stop()
    }
}
