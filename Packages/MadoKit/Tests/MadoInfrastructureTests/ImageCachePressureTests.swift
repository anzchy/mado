import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

final class CachePressureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(to value: TimeInterval) { lock.withLock { self.value = value } }
}

@Suite struct ImageCachePressureTests {
    @Test(.timeLimit(.minutes(2))) func cacheWarningCriticalTrimAndPinnedProtection() async throws {
        let cache = ImageMemoryCache(capacity: 64)
        let a = cacheKey(1), b = cacheKey(2), c = cacheKey(3), p = cacheKey(4), d = cacheKey(5)
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2), cp = try cachePixels(marker: 3)
        let pp = try cachePixels(marker: 4), dp = try cachePixels(marker: 5)
        await cache.insert(cacheImage(ap, key: a), for: a); await cache.insert(cacheImage(bp, key: b), for: b)
        await cache.insert(cacheImage(cp, key: c), for: c); await cache.pin(p, image: cacheImage(pp, key: p))
        await cache.pressure(.warning)
        #expect(await cache.image(for: a) == nil)
        #expect(await cache.image(for: b)?.image === bp)
        #expect(await cache.image(for: c)?.image === cp)
        #expect(await cache.usage() == ImageCacheUsage(entries: 3, previewBytes: 0, detailBytes: 48, pinnedBytes: 16))
        await cache.insert(cacheImage(dp, key: d), for: d)
        #expect(await cache.image(for: b) == nil)
        #expect(await cache.usage().unpinnedBytes == 32)
        await cache.pressure(.critical)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16, pinnedBytes: 16))
        await cache.insert(cacheImage(ap, key: a), for: a)
        #expect(await cache.image(for: a) == nil)
        #expect(await cache.image(for: p)?.image === pp)
        await cache.pressure(.normal)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16, pinnedBytes: 16))
    }

    @Test(.timeLimit(.minutes(2))) func cachePressureGateRefusesPrefetchButCurrentAndVisibleDecode() async throws {
        let cache = ImageMemoryCache(capacity: 100_000), decoder = CacheCountingDecoder(), trace = CacheEvents()
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache, cacheTrace: trace), file = fixture("coordinate-grid.png")
        let cached = try await pipeline.request(for: file, maximumPixelSize: 16)
        _ = try await pipeline.image(for: cached)
        await pipeline.memoryPressure(.warning); trace.reset()
        for edge in [16, 8] {
            let request = try await pipeline.request(for: file, maximumPixelSize: edge)
            let prefetch = ImageDecodeRequest(fileURL: file, maximumPixelSize: edge, renderKey: request.renderKey, priority: .prefetch)
            await #expect(performing: { try await pipeline.image(for: prefetch) }, throws: loadError(.cancelled))
        }
        #expect(trace.values.isEmpty)
        #expect(decoder.count == 1)
        await pipeline.memoryPressure(.critical)
        let refused = ImageDecodeRequest(fileURL: file, maximumPixelSize: 16, renderKey: cached.renderKey, priority: .prefetch)
        await #expect(performing: { try await pipeline.image(for: refused) }, throws: loadError(.cancelled))
        for priority in [DecodePriority.current, .visible] {
            let foreground = ImageDecodeRequest(fileURL: file, maximumPixelSize: 16, renderKey: cached.renderKey, priority: priority)
            #expect(try await pipeline.image(for: foreground).image.width == 16)
        }
        #expect(decoder.count == 3)
        #expect(await cache.usage().entries == 0)
    }

    @Test(.timeLimit(.minutes(2))) func cacheNormalRecoveryRequiresExactDelayAndResetsOnWarning() async throws {
        let clock = CachePressureClock(), decoder = CacheCountingDecoder(), cache = ImageMemoryCache(capacity: 100_000,
            pressureRecoveryDelay: 5, pressureClock: { clock.now })
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache), file = fixture("coordinate-grid.png")
        let prepared = try await pipeline.request(for: file, maximumPixelSize: 16)
        let request = ImageDecodeRequest(fileURL: file, maximumPixelSize: 16, renderKey: prepared.renderKey, priority: .prefetch)
        await pipeline.memoryPressure(.warning)
        clock.advance(to: 8)
        await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.cancelled))
        clock.advance(to: 10); await pipeline.memoryPressure(.normal)
        await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.cancelled))
        clock.advance(to: 12); await pipeline.memoryPressure(.normal)
        clock.advance(to: 14.999)
        await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.cancelled))
        clock.advance(to: 15)
        #expect(try await pipeline.image(for: request).image.width == 16)
        await pipeline.memoryPressure(.warning)
        clock.advance(to: 20); await pipeline.memoryPressure(.normal)
        clock.advance(to: 24.999)
        await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.cancelled))
        clock.advance(to: 25)
        #expect(try await pipeline.image(for: request).image.width == 16)
        #expect(decoder.count == 1)
    }

    @Test(.timeLimit(.minutes(2))) func cacheZeroRecoveryUsesDefaultMonotonicClocks() async throws {
        #expect(DecodeConfiguration().pressureRecoveryDelay == 5)
        let decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder, configuration: DecodeConfiguration(pressureRecoveryDelay: 0))
        let file = fixture("coordinate-grid.png"), prepared = try await pipeline.request(for: file, maximumPixelSize: 16)
        let request = ImageDecodeRequest(fileURL: file, maximumPixelSize: 16, renderKey: prepared.renderKey, priority: .prefetch)
        await pipeline.memoryPressure(.warning)
        await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.cancelled))
        await pipeline.memoryPressure(.normal)
        #expect(try await pipeline.image(for: request).image.width == 16)
        #expect(decoder.count == 1)
        let direct = ImageMemoryCache(capacity: 64, pressureRecoveryDelay: 0)
        await direct.pressure(.critical); await direct.pressure(.normal)
        #expect(await direct.permits(.prefetch))
    }
}
