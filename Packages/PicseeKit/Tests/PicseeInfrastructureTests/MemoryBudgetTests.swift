import CoreGraphics
import Foundation
import Testing
import PicseeCore
@testable import PicseeInfrastructure

/// One 16-byte entry or reservation (`cachePixels()`), against a 64-byte budget: B = 4C.
private let unit = 16, limit = 64

private struct BudgetRig {
    let budget = MemoryBudget(limit: limit)
    let cache: ImageMemoryCache
    let decoder = BlockingDecoder()
    let admission: DecodeAdmission
    init() {
        let cache = ImageMemoryCache(capacity: 10_000, budget: budget)
        self.cache = cache
        admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 3, visible: 3, heavy: 3, budget: limit),
            executor: OperationDecodeExecutor(workers: 3), decoder: decoder, memory: budget,
            release: { bytes in await cache.release(bytes: bytes) })
    }
    func fill(_ numbers: ClosedRange<Int>, pinned: Bool) async throws {
        for number in numbers {
            let key = cacheKey(number), image = cacheImage(try cachePixels(marker: UInt8(number)), key: key)
            if pinned { await cache.pin(key, image: image) } else { await cache.insert(image, for: key) }
        }
    }
    /// Lets every decode still held by this rig return, so a failing test cannot leave work behind.
    func releaseAll() { for _ in 0..<8 { decoder.gate.signal() } }
    func subscribe(_ number: Int, cost: Int = unit, _ priority: DecodePriority) async -> DecodeSubscription {
        await admission.subscribe(tinyRequest, key: decodeKey(number), cost: cost, heavy: false, priority: priority)
    }
}

@Suite(.timeLimit(.minutes(2))) struct MemoryBudgetTests {
    // 2.1, 2.1b–d: a full cache gives up exactly the shortfall, oldest first, before the decoder allocates.
    @Test func budgetEvictsOnlyTheShortfallBeforeTheDecodeRuns() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...4, pinned: false)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 0, evictable: 64, reserved: 0))
        let job = await rig.subscribe(100, .visible)
        var starts = rig.decoder.started.makeAsyncIterator()
        _ = await starts.next()
        #expect(await rig.cache.image(for: cacheKey(1)) == nil)
        #expect(await rig.cache.image(for: cacheKey(2)) != nil)
        #expect(await rig.cache.usage().unpinnedBytes == 3 * unit)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 0, evictable: 48, reserved: 16))
        #expect(rig.budget.peak == limit)
        rig.decoder.gate.signal()
        _ = try await job.value()
        #expect(rig.budget.usage.reserved == 0)
        #expect(rig.budget.peak == limit)
    }

    // 2.2, 2.3c(a): pins and staging block other work; `.current` waits for a running decode instead of exceeding.
    @Test func budgetPinsAndStagingQueueWorkUntilRoomReturns() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...2, pinned: true)
        var starts = rig.decoder.started.makeAsyncIterator()
        let running = await rig.subscribe(100, .visible)
        _ = await starts.next()
        let visible = await rig.subscribe(101, cost: 2 * unit, .visible)
        let current = await rig.subscribe(102, cost: 2 * unit, .current)
        try #require(await rig.admission.activity().running == 1)
        try #require(await rig.admission.activity().waiting == 2)
        rig.decoder.gate.signal()
        _ = try await running.value()
        _ = await starts.next()
        try #require(await rig.admission.activity().running == 1)
        try #require(await rig.admission.activity().reservedBytes == 2 * unit)
        rig.decoder.gate.signal()
        _ = try await current.value()
        _ = await starts.next()
        rig.decoder.gate.signal()
        _ = try await visible.value()
        #expect(rig.budget.peak == limit)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 32, evictable: 0, reserved: 0))
    }

    // 2.3, 2.3b, 2.7: with pins alone at the limit, only `.current` with nothing running may exceed.
    @Test func budgetLetsOnlyAnIdleCurrentDecodeExceedPins() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...4, pinned: true)
        let visible = await rig.subscribe(100, .visible)
        let prefetch = await rig.subscribe(101, .prefetch)
        try #require(await rig.admission.activity().running == 0)
        try #require(await rig.admission.activity().waiting == 2)
        var starts = rig.decoder.started.makeAsyncIterator()
        let current = await rig.subscribe(102, .current)
        _ = await starts.next()
        #expect(rig.budget.peak == limit + unit)
        rig.decoder.gate.signal()
        _ = try await current.value()
        #expect(await rig.admission.activity().waiting == 2)
        await visible.cancel(); await prefetch.cancel()
        for job in [visible, prefetch] {
            await #expect(throws: CancellationError.self) { try await job.value() }
        }
        #expect(await rig.admission.activity().waiting == 0)
        #expect(rig.budget.usage.reserved == 0)
    }

    // 2.3c(b): an idle `.current` evicts rather than exceeding when evictable bytes can make room.
    @Test func budgetIdleCurrentEvictsBeforeExceeding() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...3, pinned: true)
        try await rig.fill(4...4, pinned: false)
        var starts = rig.decoder.started.makeAsyncIterator()
        let current = await rig.subscribe(100, .current)
        _ = await starts.next()
        #expect(await rig.cache.image(for: cacheKey(4)) == nil)
        rig.decoder.gate.signal()
        _ = try await current.value()
        #expect(rig.budget.peak == limit)
    }

    // R1 4.1 (opus M3): eviction that cannot admit a non-current job evicts nothing; an idle `.current` takes only its shortfall.
    @Test func budgetDoesNotEvictWhenEvictionCannotAdmit() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...2, pinned: true)
        try await rig.fill(3...4, pinned: false)
        let visible = await rig.subscribe(100, cost: 3 * unit, .visible)
        var starts = rig.decoder.started.makeAsyncIterator()
        // The current job's own release runs only after any release the visible job started has finished.
        let current = await rig.subscribe(101, .current)
        _ = await starts.next()
        #expect(await rig.cache.image(for: cacheKey(3)) == nil)
        #expect(await rig.cache.image(for: cacheKey(4)) != nil)
        #expect(await rig.admission.activity().waiting == 1)
        rig.decoder.gate.signal()
        _ = try await current.value()
        await visible.cancel()
        await #expect(throws: CancellationError.self) { try await visible.value() }
        #expect(rig.budget.peak == limit)
    }

    // R1 4.1c: an idle `.current` whose shortfall exceeds the evictable bytes still evicts them all, then may exceed.
    @Test func budgetIdleCurrentEvictsEverythingEvenBeyondItsShortfall() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...3, pinned: true)
        try await rig.fill(4...4, pinned: false)
        var starts = rig.decoder.started.makeAsyncIterator()
        let current = await rig.subscribe(100, cost: 2 * unit, .current)
        _ = await starts.next()
        #expect(await rig.cache.usage().unpinnedBytes == 0)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 48, evictable: 0, reserved: 32))
        rig.decoder.gate.signal()
        _ = try await current.value()
    }

    // R1 4.1b: when the shortfall equals the evictable bytes, eviction admits a `.visible` job.
    @Test func budgetEvictsWhenTheShortfallEqualsEvictable() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        defer { rig.releaseAll() }
        try await rig.fill(1...2, pinned: true)
        try await rig.fill(3...4, pinned: false)
        var starts = rig.decoder.started.makeAsyncIterator()
        let visible = await rig.subscribe(100, cost: 2 * unit, .visible)
        _ = await starts.next()
        #expect(await rig.cache.usage().unpinnedBytes == 0)
        rig.decoder.gate.signal()
        _ = try await visible.value()
        #expect(rig.budget.peak == limit)
    }

    // 2.5, 2.6, 2.6b: inserts and pins keep pinned + evictable + reserved within the limit, and the peak sees them.
    @Test func budgetInsertsAndPinsTrimEvictableToTheRoomLeft() async throws {
        let rig = BudgetRig()
        defer { rig.decoder.gate.open() }
        rig.budget.reserved(2 * unit)
        try await rig.fill(1...1, pinned: true)
        try await rig.fill(2...4, pinned: false)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 16, evictable: 16, reserved: 32))
        #expect(await rig.cache.image(for: cacheKey(4)) != nil)
        try await rig.fill(5...5, pinned: true)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 32, evictable: 0, reserved: 32))
        #expect(rig.budget.peak == limit)
        rig.budget.reserved(0)
        try await rig.fill(6...7, pinned: false)
        #expect(rig.budget.usage == MemoryBudget.Usage(pinned: 32, evictable: 32, reserved: 0))
        #expect(rig.budget.peak == limit)
    }
}

/// Real pipeline over real pixels: costs come from the fixture's header, not from constants.
@Suite(.timeLimit(.minutes(2))) struct PipelineMemoryBudgetTests {
    private static func decodeCost(_ edge: Int) throws -> Int {
        try DecodeBudget.outputCost(width: 1280, height: 960, maximumPixelSize: edge, bytesPerPixel: 4, budget: .max)
    }

    // 2.2 through the pipeline: an unpin alone admits work that pins were holding back.
    @Test func pipelineUnpinAloneAdmitsWaitingDecode() async throws {
        let cost = try Self.decodeCost(16), limit = cost + 256
        let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit))
        let budget = try #require(pipeline.cache.budget)
        let file = fixture("coordinate-grid.png")
        var pinned: [RenderKey] = []
        // Pin real thumbnails until less than one 16-pixel decode of room is left.
        for edge in (1...15).reversed() where budget.usage.pinned <= 256 {
            let request = try await pipeline.request(for: file, maximumPixelSize: edge)
            let image = try await pipeline.image(for: request)
            await pipeline.pin(request.renderKey!, image: image)
            pinned.append(request.renderKey!)
        }
        try #require(budget.usage.pinned > 256 && budget.usage.evictable == 0)
        let request = try await pipeline.request(for: file, maximumPixelSize: 16)
        let waiting = Task { try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 16,
            renderKey: request.renderKey, priority: .visible)) }
        try await waitUntil { await pipeline.admission.activity().waiting != 0 }
        #expect(await pipeline.admission.activity().waiting == 1)
        #expect(await pipeline.admission.activity().running == 0)
        for key in pinned { await pipeline.unpin(key) }
        #expect(try await waiting.value.image.width == 16)
        #expect(budget.peak <= limit)
    }

    // 2.4: mixed priorities over a full cache all finish within the budget and leave no staging behind.
    @Test func pipelineConcurrentLoadsStayWithinBudget() async throws {
        let cost = try Self.decodeCost(16)
        let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: 3 * cost, cacheCapacity: 3 * cost))
        let budget = try #require(pipeline.cache.budget)
        let file = fixture("coordinate-grid.png")
        for edge in 1...6 { _ = try await pipeline.image(for: try await pipeline.request(for: file, maximumPixelSize: edge)) }
        let edges = Array(9...16)
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                let edge = edges[index % edges.count]
                let priority: DecodePriority = [.current, .visible, .visible][index % 3]
                group.addTask {
                    let prepared = try await pipeline.request(for: file, maximumPixelSize: edge)
                    return try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: edge,
                        renderKey: prepared.renderKey, priority: priority)).image.width
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(results.count == 20)
        #expect(budget.peak <= 3 * cost)
        #expect(budget.usage.reserved == 0)
        #expect(await pipeline.admission.activity().waiting == 0)
    }
}

// A budgeted cache keeps the default monotonic recovery clock.
@Test func budgetedCacheRecoversPrefetchOnTheDefaultClock() async {
    let cache = ImageMemoryCache(capacity: 64, budget: MemoryBudget(limit: 64), pressureRecoveryDelay: 0)
    await cache.pressure(.critical)
    #expect(await !cache.permits(.prefetch))
    await cache.pressure(.normal)
    #expect(await cache.permits(.prefetch))
}
