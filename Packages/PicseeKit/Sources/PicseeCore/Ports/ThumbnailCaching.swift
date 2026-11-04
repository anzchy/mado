import Foundation

/// Source evidence obtained while the caller holds an access lease.
public struct ThumbnailCacheTicket: Sendable {
    public let request: ImageDecodeRequest
    public let key: DurableThumbnailKey
    public let sourceSHA256: String
    public let generation: UInt64
    public init(request: ImageDecodeRequest, key: DurableThumbnailKey, sourceSHA256: String, generation: UInt64 = 0) {
        self.request = request; self.key = key; self.sourceSHA256 = sourceSHA256; self.generation = generation
    }
}

/// Called only by AccessImageSource inside its access.withLease operation.
public protocol ThumbnailCaching: Sendable {
    /// Opt in only when successful loads establish source/payload correspondence for memory retention.
    var supportsMemoryReuse: Bool { get }
    func prepare(_ request: ImageDecodeRequest) async throws -> ThumbnailCacheTicket?
    func load(_ ticket: ThumbnailCacheTicket) async throws -> DecodedImage?
    func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws
    /// True only after the supplied pixels were verified and published for this ticket.
    func storeForMemory(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws -> Bool
    /// Revalidates a proven resident buffer without allocating another pixel buffer.
    /// Source, payload, generation, and current authority must all remain valid.
    func revalidateMemory(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws -> DecodedImage?
    /// Synchronous final native-memory delivery gate, callable after the last awaited handoff.
    func memoryGenerationIsCurrent(_ ticket: ThumbnailCacheTicket) -> Bool
}

public extension ThumbnailCaching {
    var supportsMemoryReuse: Bool { false }
    func storeForMemory(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws -> Bool {
        try await store(image, for: ticket)
        return false
    }
    func revalidateMemory(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws -> DecodedImage? { nil }
    func memoryGenerationIsCurrent(_ ticket: ThumbnailCacheTicket) -> Bool { false }
}

/// Keep native-memory provenance through the lease-release handoff without changing the disk-read contract.
package struct CachedThumbnailResult: Sendable {
    package let image: DecodedImage
    package let fromMemory: Bool
    package init(image: DecodedImage, fromMemory: Bool = false) {
        self.image = image; self.fromMemory = fromMemory
    }
}

/// Configuration bridge: the public image methods on a provider never consult this cache.
package protocol ThumbnailCacheProviding: ImagePipeline {
    var thumbnailCache: (any ThumbnailCaching)? { get }
    /// Decode a disk miss from source without reusing session memory or an in-flight keyed decode.
    func imageFresh(for request: ImageDecodeRequest) async throws -> DecodedImage
    /// Loads a durable hit; a pipeline with a shared memory budget reserves room for the payload decode first.
    func cachedImage(for ticket: ThumbnailCacheTicket) async throws -> DecodedImage?
    func cachedThumbnail(for ticket: ThumbnailCacheTicket, allowingMemory: Bool) async throws -> CachedThumbnailResult?
    /// Called only under the source lease after positive durable correspondence evidence.
    func retainThumbnail(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async
}

package extension ThumbnailCacheProviding {
    func cachedImage(for ticket: ThumbnailCacheTicket) async throws -> DecodedImage? {
        try await thumbnailCache?.load(ticket)
    }
    func cachedThumbnail(for ticket: ThumbnailCacheTicket, allowingMemory: Bool) async throws -> CachedThumbnailResult? {
        try await cachedImage(for: ticket).map { CachedThumbnailResult(image: $0) }
    }
    func retainThumbnail(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async {}
}
