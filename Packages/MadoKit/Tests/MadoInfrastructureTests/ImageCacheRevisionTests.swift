import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Suite struct ImageCacheRevisionTests {
    @Test(.timeLimit(.minutes(2))) func cacheKeyValidationPrecedesLookupAndReplacementDropsOldRevision() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        let time = Date(timeIntervalSince1970: 1_000_000)
        try Data(contentsOf: fixture("orientation-1.tiff")).write(to: tree.file)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: tree.file.path)
        let events = CacheEvents(), decoder = CacheCountingDecoder(), cache = ImageMemoryCache(capacity: 1_000_000)
        let pipeline = ImageIOPipeline(decoder: decoder, identityResolver: FileItemIdentityResolver(root: tree.scope), cache: cache, cacheTrace: events)
        let oldRequest = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let oldKey = try #require(oldRequest.renderKey)
        let old = try await pipeline.image(for: oldRequest)
        let oldPreview = ImageDecodeRequest(fileURL: tree.file, maximumPixelSize: 128, renderKey: oldKey, isPreview: true)
        _ = try await pipeline.image(for: oldPreview)
        #expect(await cache.usage().entries == 2)
        try Data(contentsOf: fixture("orientation-2.tiff")).write(to: tree.file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: tree.file.path)
        events.reset()
        await #expect(performing: { try await pipeline.image(for: oldRequest) }, throws: loadError(.sourceChanged))
        #expect(events.values.isEmpty)
        let freshRequest = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let freshKey = try #require(freshRequest.renderKey)
        let fresh = try await pipeline.image(for: freshRequest)
        #expect(freshKey.itemID == oldKey.itemID)
        #expect(freshKey.revision.byteCount == oldKey.revision.byteCount)
        #expect(freshKey.revision.modificationDate == oldKey.revision.modificationDate)
        #expect(freshKey.revision.resourceIdentifier != oldKey.revision.resourceIdentifier)
        #expect(fresh.image.width == 128 && fresh.image.height == 96)
        #expect(fresh.image !== old.image)
        #expect(fresh.revision == freshKey.revision)
        #expect(decoder.count == 3)
        #expect(events.values == ["lookup(miss)"])
        #expect(await cache.image(for: oldKey) == nil)
        #expect(await cache.image(for: try #require(oldPreview.renderKey)) == nil)
        #expect(await cache.image(for: freshKey)?.image === fresh.image)
        #expect(await cache.usage().entries == 1)
    }

    @Test(.timeLimit(.minutes(2))) func cacheLateOldDecodeCannotDisplaceNewRevision() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = cacheKey(1)
        let new = RenderKey(itemID: old.itemID, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "new"), maximumPixelSize: 512)
        let oldPixels = try cachePixels(marker: 1), newPixels = try cachePixels(marker: 2)
        let oldWriter = await cache.lookup(old)
        let newWriter = await cache.lookup(new)
        _ = await cache.finish(newWriter, image: cacheImage(newPixels, key: new))
        _ = await cache.finish(oldWriter, image: cacheImage(oldPixels, key: old))
        #expect(await cache.image(for: old) == nil)
        #expect(await cache.image(for: new)?.image === newPixels)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
        let hit = await cache.lookup(new)
        #expect(hit.image?.image === newPixels)
    }

    @Test(.timeLimit(.minutes(2))) func cacheRootScopesAndFileGrantNeverCrossHit() async throws {
        let file = fixture("coordinate-grid.png"), decoder = CacheCountingDecoder(), events = CacheEvents()
        let pipeline = ImageIOPipeline(decoder: decoder, cacheTrace: events)
        let a = ItemIdentityRoot(id: AccessRootID(), url: file.deletingLastPathComponent())
        let b = ItemIdentityRoot(id: AccessRootID(), url: file.deletingLastPathComponent())
        var keys: [RenderKey] = []
        for root in [a, b, nil] {
            let request = try await pipeline.request(for: file, maximumPixelSize: 16, identityRoot: root)
            keys.append(try #require(request.renderKey))
            #expect(try await pipeline.image(for: request).image.width == 16)
        }
        #expect(keys[0].itemID != keys[1].itemID && keys[1].itemID != keys[2].itemID)
        #expect(events.values == ["lookup(miss)", "lookup(miss)", "lookup(miss)"])
        #expect(decoder.count == 3)
    }
}
