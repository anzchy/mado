import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private func observationKey(_ original: RenderKey, token: String) -> RenderKey {
    RenderKey(itemID: original.itemID,
        revision: FileRevision(byteCount: original.revision.byteCount,
            modificationDate: original.revision.modificationDate, resourceIdentifier: token),
        maximumPixelSize: original.maximumPixelSize)
}

extension ImageCacheObservationTests {
    @Test(.timeLimit(.minutes(2))) func cacheRetiredOrWrongItemObservationCannotReadOrDisturbPixels() async throws {
        let cache = ImageMemoryCache(capacity: 64), a = cacheKey(1), b = cacheKey(2)
        let pixels = try cachePixels(marker: 1)
        let retired = await cache.withObservation(itemID: a.itemID) { $0 }
        let writer = await cache.lookup(a)
        #expect(await cache.finish(writer, image: cacheImage(pixels, key: a))?.image === pixels)
        let expiredLookup = await cache.lookup(a, observation: retired)
        #expect(expiredLookup.sourceChanged && expiredLookup.image == nil)
        #expect(await cache.finish(expiredLookup, image: cacheImage(pixels, key: a)) == nil)
        await cache.withObservation(itemID: b.itemID) { wrongItem in
            let rejected = await cache.lookup(a, observation: wrongItem)
            #expect(rejected.sourceChanged && rejected.image == nil)
            #expect(await cache.finish(rejected, image: cacheImage(pixels, key: a)) == nil)
        }
        #expect(await cache.lookup(a).image?.image === pixels)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }
}

/// Holds scheduling only; identities still come from the production filesystem resolver.
private actor ObservationIdentityGate: ItemIdentityResolving {
    private let resolver: FileItemIdentityResolver
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(root: ItemIdentityRoot? = nil) {
        resolver = FileItemIdentityResolver(root: root)
        (started, signal) = AsyncStream.makeStream()
    }
    func holdNext() { armed = true }
    func release() { continuation?.resume(); continuation = nil }
    func identity(for fileURL: URL) async throws -> ItemID {
        if armed {
            armed = false
            await withCheckedContinuation { continuation = $0; signal.yield(()) }
        }
        return try await resolver.identity(for: fileURL)
    }
}

private enum ObservationFailure: Error { case expected }

@Suite struct ImageCacheObservationTests {
    @Test(.timeLimit(.minutes(2))) func cacheDelayedPinnedRevisionCannotReviveOrEvictNewPixels() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = observationKey(cacheKey(1), token: "R1")
        let new = observationKey(old, token: "R2")
        let p1 = try cachePixels(marker: 1), p2 = try cachePixels(marker: 2)
        await cache.pin(old, image: cacheImage(p1, key: old))
        let writer = await cache.lookup(new)
        #expect(await cache.finish(writer, image: cacheImage(p2, key: new))?.image === p2)
        let delayed = await cache.lookup(old)
        #expect(delayed.sourceChanged)
        #expect(delayed.image == nil)
        let otherEdge = RenderKey(itemID: old.itemID, revision: old.revision, maximumPixelSize: 256)
        let delayedOtherTier = await cache.lookup(otherEdge)
        #expect(delayedOtherTier.sourceChanged && delayedOtherTier.image == nil)
        #expect(await cache.lookup(new).image?.image === p2)
        #expect(await cache.pinCount(for: old) == 1)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32, pinnedBytes: 16))
        await cache.unpin(old)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }

    @Test(.timeLimit(.minutes(2))) func cacheDelayedRevisionPreservesPendingNewDecode() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = observationKey(cacheKey(1), token: "R1")
        let new = observationKey(old, token: "R2")
        let p1 = try cachePixels(marker: 1), p2 = try cachePixels(marker: 2)
        await cache.withObservation(itemID: old.itemID) { oldObservation in
            await cache.withObservation(itemID: new.itemID) { newObservation in
                let writer = await cache.lookup(new, observation: newObservation)
                let delayed = await cache.lookup(old, observation: oldObservation)
                #expect(delayed.sourceChanged)
                #expect(delayed.image == nil)
                #expect(await cache.finish(delayed, image: cacheImage(p1, key: old)) == nil)
                #expect(await cache.finish(writer, image: cacheImage(p2, key: new))?.image === p2)
                #expect(await cache.lookup(new).image?.image === p2)
                #expect(await cache.image(for: old) == nil)
                #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
            }
        }
    }

    @Test(.timeLimit(.minutes(2))) func cacheDelayedRevisionRejectedAfterNewPixelsEvicted() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = observationKey(cacheKey(1), token: "R1")
        let new = observationKey(old, token: "R2")
        let p1 = try cachePixels(marker: 1), p2 = try cachePixels(marker: 2)
        await cache.withObservation(itemID: old.itemID) { observation in
            let writer = await cache.lookup(new)
            #expect(await cache.finish(writer, image: cacheImage(p2, key: new))?.image === p2)
            await cache.remove(new)
            let delayed = await cache.lookup(old, observation: observation)
            #expect(delayed.sourceChanged)
            #expect(delayed.image == nil)
            #expect(await cache.finish(delayed, image: cacheImage(p1, key: old)) == nil)
            #expect(await cache.usage() == ImageCacheUsage(entries: 0, previewBytes: 0, detailBytes: 0))
        }
    }

    @Test(.timeLimit(.minutes(2))) func cacheRequestStartOrderCannotOverrideHeaderObservation() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = observationKey(cacheKey(1), token: "R1")
        let new = observationKey(old, token: "R2")
        let p1 = try cachePixels(marker: 1), p2 = try cachePixels(marker: 2)
        // A starts first but B validates R1 before A validates the replacement R2.
        await cache.withObservation(itemID: old.itemID) { a in
            await cache.withObservation(itemID: old.itemID) { b in
                let writer = await cache.lookup(new, observation: a)
                #expect(!writer.sourceChanged)
                #expect(await cache.finish(writer, image: cacheImage(p2, key: new))?.image === p2)
                let delayed = await cache.lookup(old, observation: b)
                #expect(delayed.sourceChanged)
                #expect(delayed.image == nil)
                #expect(await cache.finish(delayed, image: cacheImage(p1, key: old)) == nil)
                #expect(await cache.lookup(new).image?.image === p2)
                #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
            }
        }
    }

    @Test(.timeLimit(.minutes(2))) func cacheConcurrentSameRevisionAndUnrelatedItemRemainValid() async throws {
        let cache = ImageMemoryCache(capacity: 64), a = cacheKey(1), b = cacheKey(2)
        let newB = observationKey(b, token: "B2")
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2)
        await cache.withObservation(itemID: a.itemID) { first in
            await cache.withObservation(itemID: a.itemID) { second in
                let writerA = await cache.lookup(a, observation: first)
                let oldB = await cache.lookup(b)
                #expect(await cache.finish(oldB, image: nil) == nil)
                let writerB = await cache.lookup(newB)
                // A's repeated lookup follows B's conflicting transition, proving item isolation.
                let duplicateA = await cache.lookup(a, observation: second)
                #expect(!writerA.sourceChanged && !duplicateA.sourceChanged && !writerB.sourceChanged)
                #expect(await cache.finish(writerA, image: cacheImage(ap, key: a))?.image === ap)
                #expect(await cache.finish(duplicateA, image: cacheImage(ap, key: a))?.image === ap)
                #expect(await cache.finish(writerB, image: cacheImage(bp, key: newB))?.image === bp)
                #expect(await cache.lookup(a).image?.image === ap)
                #expect(await cache.lookup(newB).image?.image === bp)
                #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
            }
        }
    }

    @Test(.timeLimit(.minutes(2))) func cacheObservationCleanupAllowsSequentialProgressIncludingFailure() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = observationKey(cacheKey(1), token: "R1")
        let new = observationKey(old, token: "R3"), unrelated = cacheKey(2)
        let p1 = try cachePixels(marker: 1), p3 = try cachePixels(marker: 3), p2 = try cachePixels(marker: 2)
        await cache.withObservation(itemID: unrelated.itemID) { otherObservation in
            await cache.withObservation(itemID: old.itemID) { observation in
                let writer = await cache.lookup(old, observation: observation)
                #expect(await cache.finish(writer, image: cacheImage(p1, key: old))?.image === p1)
            }
            await #expect(throws: ObservationFailure.expected) {
                try await cache.withObservation(itemID: old.itemID) { _ in throw ObservationFailure.expected }
            }
            await cache.withObservation(itemID: new.itemID) { observation in
                let writer = await cache.lookup(new, observation: observation)
                #expect(!writer.sourceChanged)
                #expect(await cache.finish(writer, image: cacheImage(p3, key: new))?.image === p3)
                #expect(await cache.lookup(new).image?.image === p3)
            }
            let otherWriter = await cache.lookup(unrelated, observation: otherObservation)
            #expect(!otherWriter.sourceChanged)
            #expect(await cache.finish(otherWriter, image: cacheImage(p2, key: unrelated))?.image === p2)
            #expect(await cache.image(for: old) == nil)
            #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
        }
    }

    @Test(.timeLimit(.minutes(2))) func cachePipelineRejectsStalePinnedLookupAsSourceChanged() async throws {
        let cache = ImageMemoryCache(capacity: 100_000), decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache)
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let old = try #require(request.renderKey), new = observationKey(old, token: "R2")
        let p1 = try cachePixels(marker: 1), p2 = try cachePixels(marker: 2)
        await cache.pin(old, image: cacheImage(p1, key: old))
        let writer = await cache.lookup(new)
        _ = await cache.finish(writer, image: cacheImage(p2, key: new))
        await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.sourceChanged))
        #expect(decoder.count == 0)
        #expect(await cache.lookup(new).image?.image === p2)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32, pinnedBytes: 16))
        await cache.unpin(old)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }

    @Test(.timeLimit(.minutes(2))) func cachePipelineObservationPrecedesHeaderWithoutOldEntry() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try Data(contentsOf: fixture("orientation-1.tiff")).write(to: tree.file)
        let cache = ImageMemoryCache(capacity: 100_000), resolver = ObservationIdentityGate(root: tree.scope)
        let pipeline = ImageIOPipeline(identityResolver: resolver, cache: cache)
        let request = try await pipeline.request(for: tree.file, maximumPixelSize: 16)
        let old = try #require(request.renderKey)
        let p2 = try cachePixels(marker: 2)
        await resolver.holdNext()
        let delayed = Task { try await pipeline.image(for: request) }
        var starts = resolver.started.makeAsyncIterator()
        _ = await starts.next()
        try Data(contentsOf: fixture("orientation-2.tiff")).write(to: tree.file, options: .atomic)
        let new = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 16).renderKey)
        let writer = await cache.lookup(new)
        await resolver.release()
        await #expect(performing: { try await delayed.value }, throws: loadError(.sourceChanged))
        #expect(await cache.finish(writer, image: cacheImage(p2, key: new))?.image === p2)
        #expect(await cache.lookup(new).image?.image === p2)
        #expect(await cache.image(for: old) == nil)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }
}

extension ImageCacheObservationTests {
    @Test(.timeLimit(.minutes(2))) func cacheRawObservationBindsResolvedItemAndKeepsRevisionSafety() async throws {
        let cache = ImageMemoryCache(capacity: 64), a = cacheKey(1), b = cacheKey(2)
        let newA = observationKey(a, token: "A2"), newB = observationKey(b, token: "B2")
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2)
        await cache.withObservation { raw in
            let writerA = await cache.lookup(a, observation: raw)
            #expect(!writerA.sourceChanged)
            #expect(await cache.finish(writerA, image: cacheImage(ap, key: a))?.image === ap)
            let writerB = await cache.lookup(newB)
            #expect(await cache.finish(writerB, image: cacheImage(bp, key: newB))?.image === bp)
            #expect(await cache.lookup(a, observation: raw).image?.image === ap)
            let replacement = await cache.lookup(newA)
            #expect(await cache.finish(replacement, image: cacheImage(ap, key: newA))?.image === ap)
            let superseded = await cache.lookup(a, observation: raw)
            #expect(superseded.sourceChanged && superseded.image == nil)
            #expect(await cache.lookup(newA).image?.image === ap)
            #expect(await cache.lookup(newB).image?.image === bp)
            #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
        }
    }
}
