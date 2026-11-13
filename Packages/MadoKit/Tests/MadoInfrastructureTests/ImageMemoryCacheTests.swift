import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

func cacheKey(_ number: Int, preview: Bool = false) -> RenderKey {
    RenderKey(itemID: .ephemeral(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!),
              revision: FileRevision(byteCount: 42, modificationDate: nil), maximumPixelSize: 512, isPreview: preview)
}

func cachePixels(rows: Int = 1, depth: Int = 8, marker: UInt8 = 1) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(repeating: marker, count: 16 * rows) as CFData))
    return try #require(CGImage(width: 2, height: rows, bitsPerComponent: depth, bitsPerPixel: depth * 4,
        bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

func cacheImage(_ pixels: CGImage, key: RenderKey) -> DecodedImage {
    DecodedImage(image: pixels, sourcePixelSize: CGSize(width: pixels.width, height: pixels.height),
                 revision: key.revision, itemID: key.itemID)
}

@Suite struct ImageMemoryCacheTests {
    @Test(.timeLimit(.minutes(2))) func cacheLRUEvictsOldestAndHitRefreshes() async throws {
        let a = cacheKey(1), b = cacheKey(2), c = cacheKey(3)
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2), cp = try cachePixels(marker: 3)
        let first = ImageMemoryCache(capacity: 32)
        await first.insert(cacheImage(ap, key: a), for: a)
        await first.insert(cacheImage(bp, key: b), for: b)
        await first.insert(cacheImage(cp, key: c), for: c)
        #expect(await first.image(for: a) == nil)
        #expect(await first.image(for: b)?.image === bp)
        #expect(await first.image(for: c)?.image === cp)
        #expect(await first.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))

        let second = ImageMemoryCache(capacity: 32)
        await second.insert(cacheImage(ap, key: a), for: a)
        await second.insert(cacheImage(bp, key: b), for: b)
        #expect(await second.image(for: a)?.image === ap)
        #expect(await second.image(for: cacheKey(99)) == nil)
        await second.insert(cacheImage(cp, key: c), for: c)
        #expect(await second.image(for: b) == nil)
        #expect(await second.image(for: a)?.image === ap)
        #expect(await second.image(for: c)?.image === cp)
        #expect(await second.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
    }

    @Test(.timeLimit(.minutes(2))) func cacheActualRowsOversizeAndTierSplit() async throws {
        let p = cacheKey(1, preview: true), d = cacheKey(2), o = cacheKey(3)
        let preview = try cachePixels(rows: 2), detail = try cachePixels(rows: 2, depth: 16)
        let oversize = try cachePixels(rows: 5)
        #expect(preview.bytesPerRow == 16 && preview.height == 2 && preview.bitsPerComponent == 8)
        #expect(detail.bytesPerRow == 16 && detail.height == 2 && detail.bitsPerComponent == 16)
        let cache = ImageMemoryCache(capacity: 64)
        await cache.insert(cacheImage(preview, key: p), for: p)
        await cache.insert(cacheImage(detail, key: d), for: d)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 32, detailBytes: 32))
        await cache.insert(cacheImage(oversize, key: o), for: o)
        await cache.insert(cacheImage(oversize, key: p), for: p)
        #expect(await cache.image(for: o) == nil)
        #expect(await cache.image(for: p)?.image === preview)
        #expect(await cache.image(for: d)?.image === detail)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 32, detailBytes: 32))
        let exact = ImageMemoryCache(capacity: 32)
        await exact.insert(cacheImage(detail, key: d), for: d)
        #expect(await exact.image(for: d)?.image === detail)
        let zero = ImageMemoryCache(capacity: 0)
        await zero.insert(cacheImage(preview, key: p), for: p)
        #expect(await zero.image(for: p) == nil)
        #expect(await zero.usage() == ImageCacheUsage(entries: 0, previewBytes: 0, detailBytes: 0))
    }

    @Test(.timeLimit(.minutes(2))) func cacheDuplicateAndSharedBufferConserveBytes() async throws {
        let a = cacheKey(1, preview: true), b = cacheKey(2)
        let original = try cachePixels(), replacement = try cachePixels(rows: 2)
        let cache = ImageMemoryCache(capacity: 64)
        await cache.insert(cacheImage(original, key: a), for: a)
        await cache.insert(cacheImage(original, key: a), for: a)
        await cache.insert(cacheImage(original, key: cacheKey(1, preview: true)), for: cacheKey(1, preview: true))
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 16, detailBytes: 0))
        await cache.insert(cacheImage(replacement, key: a), for: a)
        #expect(await cache.image(for: a)?.image === replacement)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 32, detailBytes: 0))
        await cache.insert(cacheImage(replacement, key: b), for: b)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
        await cache.remove(b)
        #expect(await cache.image(for: a)?.image === replacement)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 32, detailBytes: 0))
        await cache.remove(cacheKey(99))
        await cache.remove(a)
        #expect(await cache.usage() == ImageCacheUsage(entries: 0, previewBytes: 0, detailBytes: 0))
    }

    @Test(.timeLimit(.minutes(2))) func cacheInsertEvictsMultipleEntriesUntilWithinCapacity() async throws {
        let cache = ImageMemoryCache(capacity: 64)
        let a = cacheKey(1), b = cacheKey(2), c = cacheKey(3), d = cacheKey(4)
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2), cp = try cachePixels(marker: 3)
        let dp = try cachePixels(rows: 3, marker: 4)
        await cache.insert(cacheImage(ap, key: a), for: a)
        await cache.insert(cacheImage(bp, key: b), for: b)
        await cache.insert(cacheImage(cp, key: c), for: c)
        await cache.insert(cacheImage(dp, key: d), for: d)
        #expect(await cache.image(for: a) == nil)
        #expect(await cache.image(for: b) == nil)
        #expect(await cache.image(for: c)?.image === cp)
        #expect(await cache.image(for: d)?.image === dp)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 64))
    }

    @Test func cacheConfigurationUsesQuarterBudgetAndAcceptsZero() {
        #expect(DecodeConfiguration(budget: 256).cacheCapacity == 64)
        #expect(DecodeConfiguration(budget: 256, cacheCapacity: 32).cacheCapacity == 32)
        #expect(DecodeConfiguration(budget: 256, cacheCapacity: 0).cacheCapacity == 0)
    }
}
