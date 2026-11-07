import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoApplication
import MadoCore
@testable import MadoInfrastructure

private final class DiskCountingDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        lock.withLock { value += 1 }
        return try ImageIODecoder().decode(request)
    }
}

/// One granted folder holding a real 1280×960 PNG and a durable thumbnail cache directory.
private struct DiskRig {
    let folder: URL, file: URL, cacheDirectory: URL
    let access: FileAccess
    let root: AccessRootID
    init(source: URL = fixture("coordinate-grid.png")) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("image.png")
        cacheDirectory = folder.appendingPathComponent("cache")
        try FileManager.default.copyItem(at: source, to: file)
        access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
            store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p306-r1")
        root = try await access.grant(folder: folder)
    }
    func load(_ pipeline: ImageIOPipeline, edge: Int, priority: DecodePriority) async throws -> (ImageDecodeRequest, DecodedImage) {
        let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
        do {
            let result = try await source.image(maximumPixelSize: edge, priority: priority)
            await source.close()
            return result
        } catch { await source.close(); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// Holds every disk payload read at its lease until `open()`; counts reads that reached it.
private actor DiskReadGate {
    private(set) var reads = 0
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    func pass() async {
        reads += 1
        for waiter in readWaiters { waiter.resume() }
        readWaiters.removeAll()
        if !isOpen { await withCheckedContinuation { held.append($0) } }
    }
    func untilRead() async {
        if reads > 0 { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in held { waiter.resume() }
        held.removeAll()
    }
}

/// Whether `count` jobs come to wait in admission. It sleeps between looks: a `Task.yield()` spin starved the
/// loads it waited for on the 3-core CI runner, and kept spinning after the suite's time limit cancelled the test.
/// Bounded like `waitUntil` (#392); false when the wait ended first, so the caller can cancel its load and open its
/// gate before `#require` ends the test.
private func waitUntilWaiting(_ pipeline: ImageIOPipeline, _ count: Int) async -> Bool {
    (try? await waitUntil { await pipeline.admission.activity().waiting == count }) != nil
}
/// The durable payloads the first load wrote, so the next load of that edge is a warm disk hit.
private func diskPayloads(_ rig: DiskRig) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: rig.cacheDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "png" }
}

@Suite(.timeLimit(.minutes(2))) struct MemoryBudgetDiskTests {
    /// A 16-pixel thumbnail of the fixture; the warm load reserves the square bound for that edge.
    private static let edge = 16
    private static func squareCost() throws -> Int {
        try DecodeBudget.outputCost(width: edge, height: edge, maximumPixelSize: edge, bytesPerPixel: 4, budget: .max)
    }

    // R1 2.1 (gpt F2): a warm disk-cache decode waits for the square bound of room, even when its real payload would fit,
    // holds that reservation while it decodes, and completes from disk once room frees.
    @Test func warmDiskLoadWaitsForTheSharedBudgetAndProceedsWhenRoomFrees() async throws {
        let rig = try await DiskRig()
        defer { rig.remove() }
        let square = try Self.squareCost(), limit = 2 * square, decoder = DiskCountingDecoder(), gate = DiskReadGate()
        let pipeline = ImageIOPipeline(decoder: decoder, configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit),
            thumbnailCache: ThumbnailDiskCache(directory: rig.cacheDirectory, afterReadLeaseAcquired: { await gate.pass() }))
        let budget = try #require(pipeline.cache.budget)
        let (_, source) = try await rig.load(pipeline, edge: Self.edge, priority: .visible)
        try #require(decoder.count == 1)
        try #require(try diskPayloads(rig).count == 1, "the first load left a durable payload, so the next one is warm")
        let payload = source.image.bytesPerRow * source.image.height
        try #require(payload < square && (limit - payload) % 16 == 0)
        // Native cold loads now retain proven pixels; clear residency so this fixture tests disk staging.
        await pipeline.memoryPressure(.critical)
        await pipeline.memoryPressure(.normal)
        // Leaves exactly the real payload's bytes free: enough for the pixels, not for the bound.
        let filler = cacheKey(900)
        await pipeline.pin(filler, image: cacheImage(try cachePixels(rows: (limit - payload) / 16), key: filler))
        try #require(budget.usage == MemoryBudget.Usage(pinned: limit - payload, evictable: 0, reserved: 0))
        let warm = Task { try await rig.load(pipeline, edge: Self.edge, priority: .visible) }
        let queued = await waitUntilWaiting(pipeline, 1)
        if !queued { warm.cancel(); await gate.open() }
        let activity = await pipeline.admission.activity()
        try #require(queued, "the warm load never queued in admission: \(activity)")
        #expect(await pipeline.admission.activity().waiting == 1)
        #expect(await pipeline.admission.activity().reservedBytes == 0)
        #expect(await gate.reads == 0)
        await pipeline.unpin(filler)
        await gate.untilRead()
        #expect(await pipeline.admission.activity().reservedBytes == square)
        #expect(budget.usage.reserved == square)
        await gate.open()
        let (_, image) = try await warm.value
        #expect(image.image.width == Self.edge)
        #expect(decoder.count == 1)
        #expect(budget.peak <= limit)
        #expect(budget.usage.reserved == 0)
        #expect(await pipeline.admission.activity().waiting == 0)
    }

    // R1 2.1b: a damaged payload releases its reservation and the source decode that replaces it is admitted.
    @Test func warmDiskLoadOfADamagedPayloadReleasesItsReservation() async throws {
        let rig = try await DiskRig()
        defer { rig.remove() }
        let limit = 2 * (try Self.squareCost()), decoder = DiskCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder, configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit),
            thumbnailCache: ThumbnailDiskCache(directory: rig.cacheDirectory))
        let budget = try #require(pipeline.cache.budget)
        _ = try await rig.load(pipeline, edge: Self.edge, priority: .visible)
        let payloads = try FileManager.default.contentsOfDirectory(at: rig.cacheDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        try #require(payloads.count == 1)
        try Data(repeating: 7, count: 64).write(to: payloads[0])
        let (_, image) = try await rig.load(pipeline, edge: Self.edge, priority: .visible)
        #expect(image.image.width == Self.edge)
        #expect(decoder.count == 2)
        #expect(budget.usage.reserved == 0)
        #expect(await pipeline.admission.activity().running == 0)
    }

    // R1 2.1c: a budget smaller than the square bound caps the reservation instead of refusing the load.
    // An 8×8 source asked at edge 16 costs 512 bytes to decode from source but 1024 as a square bound.
    @Test func warmDiskLoadCostIsCappedAtTheBudget() async throws {
        let small = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: small) }
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try #require(CGImageDestinationCreateWithURL(small as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let rig = try await DiskRig(source: small)
        defer { rig.remove() }
        let warmer = ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: rig.cacheDirectory))
        _ = try await rig.load(warmer, edge: Self.edge, priority: .visible)
        let limit = 600, decoder = DiskCountingDecoder()
        try #require(limit < (try Self.squareCost()))
        let pipeline = ImageIOPipeline(decoder: decoder, configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit),
            thumbnailCache: ThumbnailDiskCache(directory: rig.cacheDirectory))
        let (_, image) = try await rig.load(pipeline, edge: Self.edge, priority: .visible)
        #expect(image.image.width == 8)
        #expect(decoder.count == 0)
        #expect(try #require(pipeline.cache.budget).peak == limit)
    }

    // R1 2.2: a warm load cancelled while it waits for room leaves nothing queued or reserved.
    @Test func warmDiskLoadCancelledWhileWaitingLeavesNoStaging() async throws {
        let rig = try await DiskRig()
        defer { rig.remove() }
        let limit = 2 * (try Self.squareCost())
        let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit),
            thumbnailCache: ThumbnailDiskCache(directory: rig.cacheDirectory))
        let budget = try #require(pipeline.cache.budget)
        _ = try await rig.load(pipeline, edge: Self.edge, priority: .visible)
        try #require(try diskPayloads(rig).count == 1, "the first load left a durable payload, so the next one is warm")
        let filler = cacheKey(901)
        await pipeline.pin(filler, image: cacheImage(try cachePixels(rows: limit / 16), key: filler))
        let warm = Task { try await rig.load(pipeline, edge: Self.edge, priority: .prefetch) }
        let queued = await waitUntilWaiting(pipeline, 1)
        if !queued { warm.cancel() }
        let activity = await pipeline.admission.activity()
        try #require(queued, "the warm load never queued in admission: \(activity)")
        #expect(await pipeline.admission.activity().waiting == 1)
        warm.cancel()
        await #expect(throws: CancellationError.self) { try await warm.value }
        #expect(await pipeline.admission.activity().waiting == 0)
        #expect(budget.usage.reserved == 0)
        await pipeline.unpin(filler)
        #expect(budget.usage.pinned == 0)
    }

    // R1 3.1 (opus M2): scrolling back to a thumbnail served from disk pins one buffer, not the old evictable one as well.
    @Test func scrollBackOverTheDiskCacheHoldsOneBufferPerThumbnail() async throws {
        let rig = try await DiskRig()
        defer { rig.remove() }
        let pipeline = ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: rig.cacheDirectory))
        let budget = try #require(pipeline.cache.budget)
        let (request, first) = try await rig.load(pipeline, edge: 64, priority: .visible)
        let key = try #require(request.renderKey)
        await pipeline.pin(key, image: first)
        await pipeline.unpin(key)
        // Keep the old buffer resident but unproven, forcing disk fallback to exercise its replacement.
        await pipeline.cache.insert(first, for: key)
        let (again, second) = try await rig.load(pipeline, edge: 64, priority: .visible)
        try #require(again.renderKey == key)
        try #require(second.image !== first.image)
        await pipeline.pin(key, image: second)
        let bytes = second.image.bytesPerRow * second.image.height
        #expect(budget.usage.pinned == bytes)
        #expect(await pipeline.cache.usage().pinnedBytes == bytes)
        #expect(await pipeline.cache.usage().totalBytes == bytes)
        #expect(await pipeline.cache.pinCount(for: key) == 1)
        await pipeline.unpin(key)
        #expect(budget.usage.pinned == 0)
    }
}
