import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

/// A temporary folder holding one real PNG under an identity root, so durable cache tickets are possible.
private struct CounterRig {
    let folder: URL, file: URL, cacheDirectory: URL, root: ItemIdentityRoot
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("image.png")
        cacheDirectory = folder.appendingPathComponent("cache")
        try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: file)
        root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// Fails a request for a two-pixel edge; any other edge decodes.
private struct FailingEdgeDecoder: ImageDecoding {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        if request.maximumPixelSize == 2 { throw ImageDecodeError.unreadableImage }
        return try TinyDecoder().decode(request)
    }
}

@Test func diagnosticsMemoryCacheCountsEachLookupOutcomeOnce() async throws {
    let rig = try CounterRig()
    defer { rig.remove() }
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: rig.file, maximumPixelSize: 64, identityRoot: rig.root)
    #expect(await pipeline.cache.diagnostics() == .init(entries: 0, bytes: 0, hits: 0, misses: 0))

    _ = try await pipeline.image(for: request)
    let afterMiss = await pipeline.cache.diagnostics()
    #expect(afterMiss.hits == 0 && afterMiss.misses == 1)
    #expect(afterMiss.entries == 1)
    #expect(afterMiss.bytes == (await pipeline.cache.usage()).totalBytes && afterMiss.bytes > 0)

    _ = try await pipeline.image(for: request)
    #expect(await pipeline.cache.diagnostics() == .init(entries: 1, bytes: afterMiss.bytes, hits: 1, misses: 1))

    // Another edge is another key: its own miss, and the hit count stays.
    let other = try await pipeline.request(for: rig.file, maximumPixelSize: 32, identityRoot: rig.root)
    _ = try await pipeline.image(for: other)
    let afterOther = await pipeline.cache.diagnostics()
    #expect(afterOther.hits == 1 && afterOther.misses == 2 && afterOther.entries == 2)
}

@Test func diagnosticsDiskCacheCountsLoadOutcomesAndReadsTheIndex() async throws {
    let rig = try CounterRig()
    defer { rig.remove() }
    let pipeline = ImageIOPipeline()
    let cache = ThumbnailDiskCache(directory: rig.cacheDirectory)
    #expect(await cache.diagnostics() == .init(entries: 0, storedBytes: 0, hits: 0, misses: 0))

    let request = try await pipeline.request(for: rig.file, maximumPixelSize: 64, identityRoot: rig.root)
    let ticket = try #require(try await cache.prepare(request))
    // Preparing a ticket is not a lookup.
    #expect(await cache.diagnostics() == .init(entries: 0, storedBytes: 0, hits: 0, misses: 0))
    #expect(try await cache.load(ticket) == nil)
    #expect(await cache.diagnostics() == .init(entries: 0, storedBytes: 0, hits: 0, misses: 1))

    try await cache.store(try await pipeline.image(for: request), for: ticket)
    let payload = rig.cacheDirectory.appendingPathComponent(ticket.key.filename + ".png")
    let payloadBytes = try #require(try FileManager.default.attributesOfItem(atPath: payload.path)[.size] as? NSNumber).int64Value
    #expect(payloadBytes > 0)
    #expect(await cache.diagnostics() == .init(entries: 1, storedBytes: payloadBytes, hits: 0, misses: 1))

    #expect(try await cache.load(ticket) != nil)
    #expect(try await cache.load(ticket) != nil)
    #expect(await cache.diagnostics() == .init(entries: 1, storedBytes: payloadBytes, hits: 2, misses: 1))

    // A cancelled load is neither a hit nor a miss.
    let cancelled = Task { () async throws -> DecodedImage? in
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        return try await cache.load(ticket)
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await cache.diagnostics() == .init(entries: 1, storedBytes: payloadBytes, hits: 2, misses: 1))
}

@Test func diagnosticsDiskCacheReportsAnUnreadableIndexAsUnknown() async throws {
    let rig = try CounterRig()
    defer { rig.remove() }
    try FileManager.default.createDirectory(at: rig.cacheDirectory.appendingPathComponent("index.sqlite3"),
                                            withIntermediateDirectories: true)
    let cache = ThumbnailDiskCache(directory: rig.cacheDirectory)
    #expect(await cache.diagnostics() == .init(entries: nil, storedBytes: nil, hits: 0, misses: 0))
}

@Test func diagnosticsAdmissionCountsFinishedSourceDecodesOnly() async throws {
    let admission = DecodeAdmission(configuration: DecodeConfiguration(budget: 64),
        executor: OperationDecodeExecutor(workers: 1), decoder: FailingEdgeDecoder(),
        memory: MemoryBudget(limit: 64), release: nil)
    #expect(await admission.diagnostics() == .init(running: 0, waiting: 0, finished: 0))
    _ = try await admission.image(tinyRequest, key: decodeKey(1), cost: 4, heavy: false, priority: .current)
    #expect(await admission.diagnostics() == .init(running: 0, waiting: 0, finished: 1))
    await #expect(throws: ImageDecodeError.unreadableImage) {
        let failing = ImageDecodeRequest(fileURL: tinyRequest.fileURL, maximumPixelSize: 2)
        _ = try await admission.image(failing, key: decodeKey(2), cost: 4, heavy: false, priority: .current)
    }
    #expect(await admission.diagnostics() == .init(running: 0, waiting: 0, finished: 2))
    // A staged disk payload holds room in the same queue but is not a source decode.
    _ = try await admission.staged(tinyRequest, key: decodeKey(3), cost: 4, priority: .current) { nil }
    #expect(await admission.diagnostics() == .init(running: 0, waiting: 0, finished: 2))
}

@Test func diagnosticsDiskCacheLoadCancelledAfterItsLeaseCountsNothing() async throws {
    let rig = try CounterRig()
    defer { rig.remove() }
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: rig.file, maximumPixelSize: 64, identityRoot: rig.root)
    try await ThumbnailDiskCache(directory: rig.cacheDirectory).store(try await pipeline.image(for: request),
        for: try #require(try await ThumbnailDiskCache(directory: rig.cacheDirectory).prepare(request)))
    // The hook cancels the loading task itself, so the throw comes after the payload lease, not at entry.
    let cache = ThumbnailDiskCache(directory: rig.cacheDirectory, afterReadLeaseAcquired: {
        withUnsafeCurrentTask { $0?.cancel() }
    })
    let ticket = try #require(try await cache.prepare(request))
    let load = Task { try await cache.load(ticket) }
    await #expect(throws: CancellationError.self) { _ = try await load.value }
    let after = await cache.diagnostics()
    #expect(after.hits == 0 && after.misses == 0 && after.entries == 1)
}

@Test func diagnosticsDiskCacheEntriesFollowTheIndexThroughReplaceAndClear() async throws {
    let rig = try CounterRig()
    defer { rig.remove() }
    let pipeline = ImageIOPipeline()
    let cache = ThumbnailDiskCache(directory: rig.cacheDirectory)
    var payloads: [URL] = []
    for edge in [64, 64, 32] {
        let request = try await pipeline.request(for: rig.file, maximumPixelSize: edge, identityRoot: rig.root)
        let ticket = try #require(try await cache.prepare(request))
        try await cache.store(try await pipeline.image(for: request), for: ticket)
        payloads.append(rig.cacheDirectory.appendingPathComponent(ticket.key.filename + ".png"))
    }
    let stored = try Set(payloads).reduce(Int64(0)) { sum, payload in
        sum + (try #require(try FileManager.default.attributesOfItem(atPath: payload.path)[.size] as? NSNumber)).int64Value
    }
    // Storing one key twice replaces its row: two entries, and the bytes of the two payloads now on disk.
    #expect(await cache.diagnostics() == .init(entries: 2, storedBytes: stored, hits: 0, misses: 0))
    try await cache.clear()
    await cache.waitForPendingDeletions()
    #expect(await cache.diagnostics() == .init(entries: 0, storedBytes: 0, hits: 0, misses: 0))
}

@Test func diagnosticsAdmissionCountsOneFinishPerDecoderReturn() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(budget: 64), executor: executor, decoder: TinyDecoder())
    // Two callers coalesced on one key share one decode.
    let first = await admission.subscribe(tinyRequest, key: decodeKey(1), cost: 4, heavy: false, priority: .current)
    let second = await admission.subscribe(tinyRequest, key: decodeKey(1), cost: 4, heavy: false, priority: .current)
    #expect(executor.count == 1)
    executor.runFirst()
    _ = try await first.value(); _ = try await second.value()
    #expect(await admission.diagnostics().finished == 1)
    // An admitted decode whose only caller cancelled still ran on a worker: it counts once it returns.
    let cancelled = await admission.subscribe(tinyRequest, key: decodeKey(2), cost: 4, heavy: false, priority: .current)
    await cancelled.cancel()
    #expect(executor.count == 1)
    executor.runFirst()
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value() }
    #expect(await admission.diagnostics() == .init(running: 0, waiting: 0, finished: 2))
}

@Test func diagnosticsMemoryCacheIgnoresLookupsThatResolveNothing() async throws {
    let cache = ImageMemoryCache(capacity: 1 << 20)
    let current = decodeKey(1)
    let tiny = try TinyDecoder().decode(tinyRequest)
    await cache.pin(current, image: DecodedImage(image: tiny.image, sourcePixelSize: tiny.sourcePixelSize,
                                                 revision: current.revision, itemID: current.itemID))
    let newer = RenderKey(itemID: current.itemID, revision: FileRevision(byteCount: 2, modificationDate: nil), maximumPixelSize: 1)
    // A newer revision is a real miss, and it marks the pinned older revision stale.
    #expect(await cache.lookup(newer).image == nil)
    #expect(await cache.diagnostics().misses == 1)
    // A stale revision and a cancelled caller resolve nothing, so neither is counted.
    #expect(await cache.lookup(current).sourceChanged)
    let cancelled = Task { () -> ImageCacheRequest in
        withUnsafeCurrentTask { $0?.cancel() }
        return await cache.lookup(newer)
    }
    #expect(await cancelled.value.sourceChanged)
    let after = await cache.diagnostics()
    #expect(after.hits == 0 && after.misses == 1)
}

@Test func diagnosticsQueueShowsAHeldDiskLoadButNotAsADecode() async throws {
    let admission = DecodeAdmission(configuration: DecodeConfiguration(budget: 64),
        executor: OperationDecodeExecutor(workers: 1), decoder: TinyDecoder(), memory: MemoryBudget(limit: 64), release: nil)
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let (gate, open) = AsyncStream<Void>.makeStream()
    let load = Task {
        try await admission.staged(tinyRequest, key: decodeKey(1), cost: 4, priority: .current) {
            enter.yield()
            for await _ in gate { break }
            return nil
        }
    }
    for await _ in entered { break }
    // The disk load holds a running slot in the queue, but it is not a source decode.
    #expect(await admission.diagnostics() == .init(running: 1, waiting: 0, finished: 0))
    open.yield()
    _ = try await load.value
    #expect(await admission.diagnostics() == .init(running: 0, waiting: 0, finished: 0))
}

@Test func diagnosticsCountsAResolvedLookupEvenIfTheCallerDropsIt() async throws {
    let cache = ImageMemoryCache(capacity: 1 << 20)
    // The pipeline abandons a resolved lookup this way when its caller is cancelled after the lookup returned.
    let request = await cache.lookup(decodeKey(1))
    #expect(await cache.finish(request, image: nil) == nil)
    #expect(await cache.diagnostics().misses == 1)

    let rig = try CounterRig()
    defer { rig.remove() }
    let pipeline = ImageIOPipeline()
    let disk = ThumbnailDiskCache(directory: rig.cacheDirectory)
    let source = try await pipeline.request(for: rig.file, maximumPixelSize: 64, identityRoot: rig.root)
    let ticket = try #require(try await disk.prepare(source))
    try await disk.store(try await pipeline.image(for: source), for: ticket)
    // A hit stays counted whatever the caller then does with the image.
    _ = try await disk.load(ticket)
    #expect(await disk.diagnostics().hits == 1)
}
