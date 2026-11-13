import Foundation
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoInfrastructure

private actor CachePinObserver: ImagePresentationPinning {
    let pipeline: ImageIOPipeline
    let closed: AsyncStream<RenderKey>
    private let signal: AsyncStream<RenderKey>.Continuation
    init(_ pipeline: ImageIOPipeline) { self.pipeline = pipeline; (closed, signal) = AsyncStream.makeStream() }
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) async -> Bool { await pipeline.pin(key, image: image) }
    func unpin(_ key: RenderKey) async {
        await pipeline.unpin(key)
        if !key.isPreview { signal.yield(key) }
    }
}

@Suite struct ImageCachePinTests {
    @Test(.timeLimit(.minutes(2))) func cachePinsRefcountAndOversizeLifetime() async throws {
        let cache = ImageMemoryCache(capacity: 32), a = cacheKey(1), b = cacheKey(2), c = cacheKey(3)
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2), cp = try cachePixels(marker: 3)
        await cache.insert(cacheImage(ap, key: a), for: a)
        await cache.pin(a, image: cacheImage(ap, key: a)); await cache.pin(a, image: cacheImage(ap, key: a))
        await cache.insert(cacheImage(bp, key: b), for: b); await cache.insert(cacheImage(cp, key: c), for: c)
        #expect(await cache.pinCount(for: a) == 2)
        #expect(await cache.usage() == ImageCacheUsage(entries: 3, previewBytes: 0, detailBytes: 48, pinnedBytes: 16))
        await cache.unpin(a)
        #expect(await cache.pinCount(for: a) == 1)
        await cache.trim(to: 0)
        #expect(await cache.image(for: a)?.image === ap)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16, pinnedBytes: 16))
        await cache.unpin(a)
        #expect(await cache.pinCount(for: a) == 0)
        #expect(await cache.usage().entries == 0)
        let oversize = ImageMemoryCache(capacity: 32), o = cacheKey(4), op = try cachePixels(rows: 3)
        await oversize.pin(o, image: cacheImage(op, key: o)); await oversize.pin(o, image: cacheImage(op, key: o))
        #expect(await oversize.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 48, pinnedBytes: 48))
        await oversize.unpin(o)
        #expect(await oversize.image(for: o)?.image === op)
        await oversize.unpin(o); await oversize.unpin(o)
        #expect(await oversize.image(for: o) == nil)
        #expect(await oversize.pinCount(for: o) == 0)
    }

    @Test(.timeLimit(.minutes(2))) func cachePinnedMultiEvictionAndLastUnpinImmediatelyRestoreBound() async throws {
        let cache = ImageMemoryCache(capacity: 64), a = cacheKey(1), b = cacheKey(2), c = cacheKey(3), d = cacheKey(4)
        let ap = try cachePixels(), bp = try cachePixels(marker: 2), cp = try cachePixels(marker: 3), dp = try cachePixels(rows: 4)
        await cache.pin(a, image: cacheImage(ap, key: a))
        await cache.insert(cacheImage(bp, key: b), for: b); await cache.insert(cacheImage(cp, key: c), for: c)
        await cache.insert(cacheImage(dp, key: d), for: d)
        #expect(await cache.image(for: b) == nil)
        #expect(await cache.image(for: c) == nil)
        #expect(await cache.image(for: a)?.image === ap)
        #expect(await cache.image(for: d)?.image === dp)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 80, pinnedBytes: 16))

        let normal = ImageMemoryCache(capacity: 32)
        await normal.pin(a, image: cacheImage(ap, key: a)); await normal.pin(a, image: cacheImage(ap, key: a))
        await normal.insert(cacheImage(bp, key: b), for: b); await normal.insert(cacheImage(cp, key: c), for: c)
        await normal.unpin(a)
        #expect(await normal.usage() == ImageCacheUsage(entries: 3, previewBytes: 0, detailBytes: 48, pinnedBytes: 16))
        await normal.unpin(a)
        #expect(await normal.image(for: a) == nil)
        #expect(await normal.image(for: b)?.image === bp)
        #expect(await normal.image(for: c)?.image === cp)
        #expect(await normal.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
    }

    @Test(.timeLimit(.minutes(2))) func cacheZeroTrimDropsUnpinnedAliasAndOldRevisionWaitsForUnpin() async throws {
        let cache = ImageMemoryCache(capacity: 64), a = cacheKey(1), alias = cacheKey(2, preview: true)
        let pixels = try cachePixels()
        await cache.pin(a, image: cacheImage(pixels, key: a))
        await cache.insert(cacheImage(pixels, key: alias), for: alias)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 16, pinnedBytes: 16))
        await cache.trim(to: 0)
        #expect(await cache.image(for: alias) == nil)
        #expect(await cache.image(for: a)?.image === pixels)
        #expect(await cache.usage().entries == 1)
        await cache.unpin(a)
        #expect(await cache.usage().entries == 0)

        let revisions = ImageMemoryCache(capacity: 64)
        let newer = RenderKey(itemID: a.itemID, revision: FileRevision(byteCount: 43, modificationDate: nil), maximumPixelSize: 512)
        let fresh = try cachePixels(marker: 2)
        await revisions.pin(a, image: cacheImage(pixels, key: a))
        let request = await revisions.lookup(newer)
        _ = await revisions.finish(request, image: cacheImage(fresh, key: newer))
        #expect(await revisions.image(for: a)?.image === pixels)
        #expect(await revisions.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32, pinnedBytes: 16))
        await revisions.unpin(a)
        #expect(await revisions.image(for: a) == nil)
        #expect(await revisions.image(for: newer)?.image === fresh)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true]) func cachePinGapAccountsForDistinctSameKeyBuffers(reverse: Bool) async throws {
        let cache = ImageMemoryCache(capacity: 16), key = cacheKey(1), filler = cacheKey(2)
        let a = try cachePixels(marker: 1), b = try cachePixels(marker: 2), c = try cachePixels(marker: 3)
        await cache.insert(cacheImage(a, key: key), for: key)
        await cache.insert(cacheImage(c, key: filler), for: filler)
        #expect(await cache.image(for: key) == nil)
        let late = await cache.lookup(key)
        await cache.insert(cacheImage(b, key: key), for: key)
        for pixels in reverse ? [b, a] : [a, b] { await cache.pin(key, image: cacheImage(pixels, key: key)) }
        #expect(await cache.pinCount(for: key) == 2)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 32, pinnedBytes: 32))
        await cache.insert(cacheImage(c, key: key), for: key)
        // The first pin replaced the unpinned buffer (#139 R1); the late finish still receives the one retained buffer.
        let retained = reverse ? b : a
        #expect(await cache.finish(late, image: cacheImage(c, key: key))?.image === retained)
        #expect(await cache.image(for: key)?.image === retained)
        await cache.pin(key, image: cacheImage(b, key: key))
        #expect(await cache.pinCount(for: key) == 3)
        await cache.pin(key, image: cacheImage(a, key: key))
        #expect(await cache.pinCount(for: key) == 4)
        #expect(await cache.usage().pinnedBytes == 32)
        await cache.unpin(key)
        await cache.trim(to: 0); await cache.remove(key)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 32, pinnedBytes: 32))
        await cache.unpin(key); await cache.unpin(key)
        #expect(await cache.pinCount(for: key) == 1)
        #expect(await cache.usage().pinnedBytes == 32)
        await cache.unpin(key)
        #expect(await cache.usage() == ImageCacheUsage(entries: 0, previewBytes: 0, detailBytes: 0))
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func cacheTwoSessionsSharePinsOnRealPipeline() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000), decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache), port = CachePinObserver(pipeline)
        let access = CacheLeases(), a = ViewerSession(imageLoader: ViewerImageLoader(trace: nil, presentation: port))
        let b = ViewerSession(imageLoader: ViewerImageLoader(trace: nil, presentation: port)), ah = CacheHost(), bh = CacheHost()
        a.imageLoader.host = ah; b.imageLoader.host = bh
        let file = fixture("coordinate-grid.png")
        for session in [a, b] {
            session.openImage(file, maximumPixelSize: 16) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
            await session.imageLoader.loadTask?.value
        }
        let key = try #require(b.imageLoader.presented?.key)
        #expect(await cache.pinCount(for: key) == 2)
        #expect(ah.images.last === bh.images.last)
        #expect(decoder.count == 2)
        #expect(await cache.usage().pinnedBytes == 192)
        var closed = port.closed.makeAsyncIterator()
        let pinning = await cache.pinCount(for: key) == 2
        a.closeImage()
        if pinning { #expect(await closed.next() == key) }
        #expect(await cache.pinCount(for: key) == 1)
        #expect(b.imageLoader.phase == .settled && b.imageLoader.presented?.key == key)
        await cache.trim(to: 0)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 192, pinnedBytes: 192))
        b.closeImage()
        if pinning { #expect(await closed.next() == key) }
        #expect(await cache.usage().entries == 0)
        await access.waitUntilEmpty()
    }
}
