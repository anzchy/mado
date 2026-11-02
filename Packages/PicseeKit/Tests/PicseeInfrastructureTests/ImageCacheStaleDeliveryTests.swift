import Foundation
import Testing
import PicseeCore
@testable import PicseeInfrastructure

@Suite struct ImageCacheStaleDeliveryTests {
    @Test(.timeLimit(.minutes(2))) func cacheNewerObservationRejectsLateMatchingOldResult() async throws {
        let decoder = CacheBlockingDecoder(), cache = ImageMemoryCache(capacity: 100_000)
        defer { decoder.gate.open() }
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache)
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let old = try #require(request.renderKey)
        let task = Task { try await pipeline.image(for: request) }
        var starts = decoder.started.makeAsyncIterator()
        _ = await starts.next()

        // Simulate a newer leased observation at the real cache boundary. The real file stays old,
        // so the blocked decoder's post-decode revision will still match its admitted old key.
        let newer = RenderKey(itemID: old.itemID,
            revision: FileRevision(byteCount: old.revision.byteCount, modificationDate: old.revision.modificationDate,
                                   resourceIdentifier: "synthetic-new-observation"),
            maximumPixelSize: old.maximumPixelSize)
        let pixels = try cachePixels(marker: 7)
        let observation = await cache.lookup(newer)
        _ = await cache.finish(observation, image: cacheImage(pixels, key: newer))
        #expect(await cache.image(for: newer)?.image === pixels)
        decoder.gate.signal()

        await #expect(performing: { try await task.value }, throws: loadError(.sourceChanged))
        #expect(decoder.count == 1)
        #expect(await cache.image(for: old) == nil)
        #expect(await cache.image(for: newer)?.image === pixels)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }
}
