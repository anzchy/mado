import CoreGraphics
import Foundation
import PicseeApplication
import PicseeCore
import Testing

/// The synchronous generation gate shares state with the awaited lease-release handoff.
private final class RetryGenerationCache: ThumbnailCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var invalidateOnRelease = false
    private var prepared: [UInt64] = []
    private var checked: [Bool] = []
    var supportsMemoryReuse: Bool { true }

    func armAfterMemoryHit() { lock.withLock { invalidateOnRelease = true } }
    func leaseReleased() {
        lock.withLock {
            if invalidateOnRelease {
                generation += 1
                invalidateOnRelease = false
            }
        }
    }
    func prepare(_ request: ImageDecodeRequest) async throws -> ThumbnailCacheTicket? {
        let renderKey = try #require(request.renderKey)
        let digest = String(repeating: "a", count: 64)
        let key = try #require(DurableThumbnailKey(renderKey: renderKey, sourceSHA256: digest))
        return lock.withLock {
            prepared.append(generation)
            return ThumbnailCacheTicket(request: request, key: key, sourceSHA256: digest, generation: generation)
        }
    }
    func load(_ ticket: ThumbnailCacheTicket) async throws -> DecodedImage? { nil }
    func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws {}
    func memoryGenerationIsCurrent(_ ticket: ThumbnailCacheTicket) -> Bool {
        lock.withLock {
            let current = ticket.generation == generation
            checked.append(current)
            return current
        }
    }
    var observations: (prepared: [UInt64], checked: [Bool]) {
        lock.withLock { (prepared, checked) }
    }
}

private actor RetryGenerationAccess: AccessLeasing {
    let cache: RetryGenerationCache
    let root: AccessRootID
    private(set) var acquired: [AccessLease] = []
    private(set) var released: [AccessLease] = []
    init(cache: RetryGenerationCache, root: AccessRootID) { self.cache = cache; self.root = root }
    func acquire(_ request: AccessRequest) async throws -> AccessLease {
        let file: URL
        switch request { case .root(_, let url), .fileGrant(let url): file = url }
        let lease = AccessLease(url: file.deletingLastPathComponent(), rootID: root)
        acquired.append(lease)
        return lease
    }
    func release(_ lease: AccessLease) async {
        // withLease has already obtained its memory hit, but cannot return it until this finishes.
        cache.leaseReleased()
        released.append(lease)
    }
}

private actor RetryGenerationPipeline: ThumbnailCacheProviding {
    nonisolated let thumbnailCache: (any ThumbnailCaching)?
    let cache: RetryGenerationCache
    let key: RenderKey
    let memory: DecodedImage
    let fresh: DecodedImage
    private(set) var memoryAllowed: [Bool] = []
    private(set) var freshDecodes = 0
    private(set) var ordinaryDecodes = 0

    init(cache: RetryGenerationCache, key: RenderKey, memory: DecodedImage, fresh: DecodedImage) {
        self.cache = cache; thumbnailCache = cache; self.key = key
        self.memory = memory; self.fresh = fresh
    }
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key)
    }
    func cachedThumbnail(for ticket: ThumbnailCacheTicket, allowingMemory: Bool) async throws -> CachedThumbnailResult? {
        memoryAllowed.append(allowingMemory)
        guard allowingMemory else { return nil }
        cache.armAfterMemoryHit()
        return CachedThumbnailResult(image: memory, fromMemory: true)
    }
    func imageFresh(for request: ImageDecodeRequest) async throws -> DecodedImage {
        freshDecodes += 1
        return fresh
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        ordinaryDecodes += 1
        return memory
    }
}

private func retryGenerationImage(key: RenderKey, red: CGFloat) throws -> DecodedImage {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 2, height: 2),
        revision: key.revision, itemID: key.itemID)
}

@Test(.timeLimit(.minutes(2)))
func issue475StaleMemoryGenerationRetriesFreshAfterLeaseRelease() async throws {
    let root = AccessRootID(), file = URL(fileURLWithPath: "/tmp/issue475/image.png")
    let key = RenderKey(itemID: .rootRelative(rootID: root, relativePath: "image.png"),
        revision: FileRevision(byteCount: 16, modificationDate: nil), maximumPixelSize: 64)
    let memory = try retryGenerationImage(key: key, red: 1)
    let fresh = try retryGenerationImage(key: key, red: 0)
    let cache = RetryGenerationCache(), access = RetryGenerationAccess(cache: cache, root: root)
    let pipeline = RetryGenerationPipeline(cache: cache, key: key, memory: memory, fresh: fresh)
    let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)

    let (request, delivered): (ImageDecodeRequest, DecodedImage)
    do {
        (request, delivered) = try await source.image(maximumPixelSize: 64, priority: .visible)
    } catch { await source.close(); throw error }
    #expect(delivered.image === fresh.image)
    #expect(delivered.image !== memory.image)
    #expect(request.fileURL == file && request.renderKey == key)
    #expect(request.maximumPixelSize == 64 && request.priority == .visible)
    #expect(await pipeline.memoryAllowed == [true, false])
    #expect(await pipeline.freshDecodes == 1)
    #expect(await pipeline.ordinaryDecodes == 0)
    #expect(cache.observations.prepared == [0, 1])
    #expect(cache.observations.checked == [false])

    let acquired = await access.acquired, beforeClose = await access.released
    #expect(acquired.count == 3) // Display lease plus one decode lease per attempt.
    #expect(beforeClose == Array(acquired.dropFirst()))
    await source.close()
    let released = await access.released
    #expect(Set(released) == Set(acquired))
    #expect(released.count == acquired.count)
}
