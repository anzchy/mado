import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Suite struct ImageCacheKeyTests {
    @Test(arguments: 0..<10) func cacheFullKeyFieldsAreIndependent(field: Int) async throws {
        let item = cacheKey(1).itemID
        func key(changing field: Int? = nil) -> RenderKey {
            RenderKey(itemID: field == 0 ? cacheKey(2).itemID : item,
                revision: FileRevision(byteCount: field == 1 ? 43 : 42,
                    modificationDate: Date(timeIntervalSinceReferenceDate: field == 2 ? 2 : 1),
                    resourceIdentifier: field == 3 ? "new" : "old"),
                maximumPixelSize: field == 5 ? 1024 : 512, isPreview: field == 6,
                frameIndex: field == 4 ? 1 : 0, policy: field == 7 ? .unorientedSDR : .orientedSDR,
                decoderVersion: field == 8 ? 2 : 1, purpose: field == 9 ? .thumbnail : .viewer)
        }
        let original = key(), pixels = try cachePixels(), cache = ImageMemoryCache(capacity: 64)
        await cache.insert(cacheImage(pixels, key: original), for: original)
        #expect(await cache.image(for: key(changing: field)) == nil)
        #expect(await cache.image(for: key())?.image === pixels)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }
}
