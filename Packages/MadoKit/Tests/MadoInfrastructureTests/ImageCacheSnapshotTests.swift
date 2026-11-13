import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

final class CacheSnapshotRecorder: ResourceSnapshotTracing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ResourceSnapshot] = []
    private var outcomes: [String] = []
    var values: [ResourceSnapshot] { lock.withLock { stored } }
    var lookups: [String] { lock.withLock { outcomes } }
    var rows: [[Int]] { values.map { [$0.entries, $0.previewBytes, $0.detailBytes, $0.pinnedBytes, $0.reservedBytes, $0.running, $0.waiting] } }
    func lookup(isPreview: Bool, hit: Bool) {
        lock.withLock { outcomes.append("\(isPreview ? "preview" : "detail"):\(hit ? "hit" : "miss")") }
    }
    func snapshot(_ snapshot: ResourceSnapshot) { lock.withLock { stored.append(snapshot) } }
}

@Suite struct ImageCacheSnapshotTests {
    @Test(.timeLimit(.minutes(2))) func cacheSnapshotScriptHasLiteralFieldsAndLookupOutcomes() async throws {
        let recorder = CacheSnapshotRecorder(), cache = ImageMemoryCache(capacity: 32)
        let admission = DecodeAdmission(configuration: DecodeConfiguration(budget: 64), executor: ControlledExecutor(), decoder: TinyDecoder())
        let context = ResourceSnapshotContext(tracer: recorder, activity: await admission.activity())
        let a = cacheKey(1, preview: true), b = cacheKey(2), c = cacheKey(3)
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2), cp = try cachePixels(marker: 3)
        await cache.insert(cacheImage(ap, key: a), for: a, context: context)
        await cache.insert(cacheImage(bp, key: b), for: b, context: context)
        #expect(await cache.lookup(a, context: context).image?.image === ap)
        let miss = await cache.lookup(cacheKey(99), context: context)
        _ = await cache.finish(miss, image: nil, context: context)
        await cache.insert(cacheImage(cp, key: c), for: c, context: context)
        await cache.pin(a, image: cacheImage(ap, key: a), context: context)
        await cache.unpin(a, context: context)
        let newer = RenderKey(itemID: c.itemID, revision: FileRevision(byteCount: 43, modificationDate: nil), maximumPixelSize: 512)
        let changed = await cache.lookup(newer, context: context)
        _ = await cache.finish(changed, image: nil, context: context)
        await cache.pressure(.warning, context: context)
        await cache.pressure(.critical, context: context)
        await cache.pressure(.normal, context: context)
        await cache.pressure(.normal, context: context)
        await cache.insert(cacheImage(try cachePixels(rows: 3), key: b), for: b, context: context)
        #expect(recorder.rows == [
            [1, 16, 0, 0, 0, 0, 0], [2, 16, 16, 0, 0, 0, 0], [2, 16, 16, 0, 0, 0, 0],
            [3, 16, 32, 0, 0, 0, 0], [2, 16, 16, 0, 0, 0, 0],
            [2, 16, 16, 16, 0, 0, 0], [2, 16, 16, 0, 0, 0, 0], [1, 16, 0, 0, 0, 0, 0],
            [1, 16, 0, 0, 0, 0, 0], [1, 16, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]
        ])
        #expect(recorder.values.map(\.pressure) == [.normal, .normal, .normal, .normal, .normal, .normal, .normal, .normal,
                                                   .warning, .critical, .critical, .normal])
        #expect(recorder.lookups == ["preview:hit", "detail:miss", "detail:miss"])
        #expect(recorder.values.allSatisfy { $0.rss == "unknown" && $0.retainedObjects == "unknown" })
        #expect(await cache.usage().entries == 0)
    }

    @Test(.timeLimit(.minutes(2))) func cacheSnapshotIncludesActualAdmissionActivity() async throws {
        let recorder = CacheSnapshotRecorder(), cache = ImageMemoryCache(capacity: 32), executor = ControlledExecutor()
        let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 32), executor: executor, decoder: TinyDecoder())
        let first = await admission.subscribe(tinyRequest, key: decodeKey(90), cost: 16, heavy: false, priority: .current)
        let second = await admission.subscribe(tinyRequest, key: decodeKey(91), cost: 16, heavy: false, priority: .current)
        let key = cacheKey(1), pixels = try cachePixels()
        await cache.insert(cacheImage(pixels, key: key), for: key,
            context: ResourceSnapshotContext(tracer: recorder, activity: await admission.activity()))
        #expect(executor.count == 1)
        executor.runFirst(); #expect(try await first.value().image.width == 1)
        executor.runFirst(); #expect(try await second.value().image.width == 1)
        await cache.pressure(.warning, context: ResourceSnapshotContext(tracer: recorder, activity: await admission.activity()))
        #expect(recorder.rows == [[1, 0, 16, 0, 16, 1, 1], [1, 0, 16, 0, 0, 0, 0]])
        #expect(recorder.values.map(\.pressure) == [.normal, .warning])
    }

    @Test(.timeLimit(.minutes(2))) func cachePipelineConnectsMutationSnapshotsAndOneLookupPerRequest() async throws {
        let recorder = CacheSnapshotRecorder(), cache = ImageMemoryCache(capacity: 100_000), decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache, cacheTrace: recorder)
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let image = try await pipeline.image(for: request), key = try #require(request.renderKey)
        #expect(try await pipeline.image(for: request).image === image.image)
        await pipeline.pin(key, image: image); await pipeline.unpin(key)
        await pipeline.memoryPressure(.critical)
        #expect(decoder.count == 1)
        #expect(recorder.lookups == ["detail:miss", "detail:hit"])
        #expect(recorder.rows == [[1, 0, 192, 0, 0, 0, 0], [1, 0, 192, 0, 0, 0, 0],
                                 [1, 0, 192, 192, 0, 0, 0], [1, 0, 192, 0, 0, 0, 0],
                                 [1, 0, 192, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]])
        #expect(recorder.values.map(\.pressure) == [.normal, .normal, .normal, .normal, .critical, .critical])
    }
}
