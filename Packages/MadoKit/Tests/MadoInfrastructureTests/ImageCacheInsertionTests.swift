import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private final class CacheFailingDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    var count: Int { lock.withLock { runs } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        lock.withLock { runs += 1 }
        throw ImageDecodeError.unreadableImage
    }
}

final class CacheBlockingDecoder: ImageDecoding, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    let gate = TestGate()
    private let lock = NSLock()
    private var runs = 0
    var count: Int { lock.withLock { runs } }
    init() { (started, signal) = AsyncStream.makeStream() }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let first = lock.withLock { runs += 1; return runs == 1 }
        if first { signal.yield(()); gate.wait() }
        return try ImageIODecoder().decode(request)
    }
}

private final class CacheMutatingDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    var count: Int { lock.withLock { runs } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let first = lock.withLock { runs += 1; return runs == 1 }
        let image = try ImageIODecoder().decode(request)
        if first { try Data(contentsOf: fixture("orientation-2.tiff")).write(to: request.fileURL, options: .atomic) }
        return image
    }
}

private struct CacheCancelOnHit: ResourceSnapshotTracing {
    func lookup(isPreview: Bool, hit: Bool) {
        if hit { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@Suite struct ImageCacheInsertionTests {
    @Test(.timeLimit(.minutes(2))) func cacheRejectsMismatchedIdentityAndRevision() async throws {
        let cache = ImageMemoryCache(capacity: 64), a = cacheKey(1), b = cacheKey(2)
        let ap = try cachePixels(marker: 1), bp = try cachePixels(marker: 2)
        await cache.insert(cacheImage(ap, key: a), for: a)
        let mismatches = [
            DecodedImage(image: bp, sourcePixelSize: .zero, revision: b.revision, itemID: a.itemID),
            DecodedImage(image: bp, sourcePixelSize: .zero, revision: FileRevision(byteCount: 99, modificationDate: nil), itemID: b.itemID),
            DecodedImage(image: bp, sourcePixelSize: .zero, revision: b.revision),
            DecodedImage(image: bp, sourcePixelSize: .zero, itemID: b.itemID)
        ]
        for image in mismatches {
            let request = await cache.lookup(b)
            _ = await cache.finish(request, image: image)
            #expect(await cache.image(for: a)?.image === ap)
            #expect(await cache.image(for: b) == nil)
            #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
        }
        let request = await cache.lookup(b)
        _ = await cache.finish(request, image: cacheImage(bp, key: b))
        #expect(await cache.image(for: b)?.image === bp)
        #expect(await cache.usage() == ImageCacheUsage(entries: 2, previewBytes: 0, detailBytes: 32))
    }

    @Test(.timeLimit(.minutes(2))) func cacheDuplicateCompletionCanonicalizesStoredBuffer() async throws {
        let cache = ImageMemoryCache(capacity: 64), key = cacheKey(1)
        let first = await cache.lookup(key), second = await cache.lookup(key)
        let a = try cachePixels(marker: 1), b = try cachePixels(marker: 2)
        let accepted = await cache.finish(first, image: cacheImage(a, key: key))
        let duplicate = await cache.finish(second, image: cacheImage(b, key: key))
        #expect(accepted?.image === a && duplicate?.image === a)
        #expect(await cache.image(for: key)?.image === a)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
        _ = await cache.finish(second, image: cacheImage(b, key: key))
        #expect(await cache.image(for: key)?.image === a)
    }

    @Test(.timeLimit(.minutes(2))) func cacheCancellationAtHitAndCompletionCannotDeliverOrInsert() async throws {
        let cache = ImageMemoryCache(capacity: 100_000), decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache, cacheTrace: CacheCancelOnHit())
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let seed = try await pipeline.image(for: request)
        let hit = Task { try await pipeline.image(for: request) }
        await #expect(performing: { try await hit.value }, throws: loadError(.cancelled))
        #expect(decoder.count == 1)
        #expect(await cache.image(for: try #require(request.renderKey))?.image === seed.image)
        let key = cacheKey(1), image = cacheImage(try cachePixels(), key: key)
        let writer = await cache.lookup(key)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.finish(writer, image: image)
        }
        _ = await cancelled.value
        #expect(await cache.image(for: key) == nil)
        _ = await cache.finish(writer, image: image)
        #expect(await cache.image(for: key) == nil)
    }

    @Test(.timeLimit(.minutes(2))) func cacheFailureAndResourceLimitInsertNothing() async throws {
        let cache = ImageMemoryCache(capacity: 100_000), a = cacheKey(1), ap = try cachePixels()
        await cache.insert(cacheImage(ap, key: a), for: a)
        let decoder = CacheFailingDecoder(), file = fixture("coordinate-grid.png")
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache)
        let request = try await pipeline.request(for: file, maximumPixelSize: 16)
        for _ in 0..<2 {
            await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.corruptImage))
            #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
        }
        #expect(decoder.count == 2)
        let budgetDecoder = CacheCountingDecoder()
        let limited = ImageIOPipeline(decoder: budgetDecoder, configuration: DecodeConfiguration(budget: 1), cache: cache)
        await #expect(performing: { try await limited.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 16)) }, throws: loadError(.resourceLimit))
        #expect(budgetDecoder.count == 0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.image(for: request)
        }
        await #expect(performing: { try await cancelled.value }, throws: loadError(.cancelled))
        #expect(decoder.count == 2)
        #expect(await cache.image(for: a)?.image === ap)
        #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
    }

    @Test(.timeLimit(.minutes(2))) func cacheCancelledRunningResultNeverBecomesReusable() async throws {
        let decoder = CacheBlockingDecoder(), cache = ImageMemoryCache(capacity: 100_000)
        defer { decoder.gate.open() }
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache)
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let task = Task { try await pipeline.image(for: request) }
        var starts = decoder.started.makeAsyncIterator()
        _ = await starts.next()
        task.cancel()
        #expect(await cache.usage().entries == 0)
        decoder.gate.signal()
        await #expect(performing: { try await task.value }, throws: loadError(.cancelled))
        #expect(await cache.usage().entries == 0)
        #expect(try await pipeline.image(for: request).image.width == 16)
        #expect(decoder.count == 2)
        #expect(await cache.usage().entries == 1)
    }

    @Test(.timeLimit(.minutes(2))) func cacheChangedDuringDecodeDoesNotInsert() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try Data(contentsOf: fixture("orientation-1.tiff")).write(to: tree.file)
        let decoder = CacheMutatingDecoder(), cache = ImageMemoryCache(capacity: 1_000_000)
        let pipeline = ImageIOPipeline(decoder: decoder, identityResolver: FileItemIdentityResolver(root: tree.scope), cache: cache)
        let oldRequest = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let old = try await pipeline.image(for: oldRequest)
        #expect(old.revision != oldRequest.renderKey?.revision)
        #expect(await cache.usage().entries == 0)
        let request = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let fresh = try await pipeline.image(for: request)
        #expect(fresh.image.width == 128 && fresh.image.height == 96)
        #expect(fresh.revision == request.renderKey?.revision)
        #expect(fresh.image !== old.image)
        #expect(decoder.count == 2)
        #expect(await cache.usage().entries == 1)
        _ = try await pipeline.image(for: request)
        #expect(decoder.count == 2)
    }
}
