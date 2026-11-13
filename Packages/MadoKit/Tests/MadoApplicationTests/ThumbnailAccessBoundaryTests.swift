import CoreGraphics
import Foundation
import MadoCore
import MadoApplication
import Testing

private actor P303BoundaryAccess: AccessLeasing {
    let root: ItemIdentityRoot
    init(root: ItemIdentityRoot) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease {
        AccessLease(url: root.url, rootID: root.id)
    }
    func release(_ lease: AccessLease) { }
}

private actor P303WrongCache: ThumbnailCaching {
    func prepare(_ request: ImageDecodeRequest) -> ThumbnailCacheTicket? {
        guard let render = request.renderKey else { return nil }
        let sha = String(repeating: "a", count: 64)
        guard let key = DurableThumbnailKey(renderKey: render, sourceSHA256: sha) else { return nil }
        return ThumbnailCacheTicket(request: request, key: key, sourceSHA256: sha)
    }
    func load(_ ticket: ThumbnailCacheTicket) -> DecodedImage? {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: FileRevision(byteCount: 1, modificationDate: nil, resourceIdentifier: "wrong"),
            itemID: ticket.request.renderKey?.itemID)
    }
    func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) { }
}

private actor P303BoundaryPipeline: ThumbnailCacheProviding {
    let thumbnailCache: (any ThumbnailCaching)? = P303WrongCache()
    private(set) var decodeCalls = 0
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) -> ImageDecodeRequest {
        let root = identityRoot!
        let key = RenderKey(itemID: .rootRelative(rootID: root.id, relativePath: fileURL.lastPathComponent),
            revision: FileRevision(byteCount: 1, modificationDate: nil, resourceIdentifier: "session"),
            maximumPixelSize: maximumPixelSize)
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key)
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage {
        decodeCalls += 1
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: request.renderKey?.revision, itemID: request.renderKey?.itemID)
    }
    func imageFresh(for request: ImageDecodeRequest) -> DecodedImage {
        image(for: request)
    }
}

@Test(.timeLimit(.minutes(2))) func p303AccessBoundaryRejectsCachePixelsWithWrongRevision() async throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp"))
    let pipeline = P303BoundaryPipeline()
    let file = root.url.appendingPathComponent("image.png")
    let source = try await AccessImageSource.open(.root(root.id, file: file),
        access: P303BoundaryAccess(root: root), pipeline: pipeline)
    let (request, image) = try await source.image(maximumPixelSize: 128)
    #expect(image.itemID == request.renderKey?.itemID)
    #expect(image.revision == request.renderKey?.revision)
    #expect(await pipeline.decodeCalls == 1)
    await source.close()
}

private actor P303DenyReacquire: AccessLeasing {
    let root: ItemIdentityRoot
    private var attempts = 0
    init(root: ItemIdentityRoot) { self.root = root }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        attempts += 1
        if attempts > 1 { throw FileAccessError.startFailed }
        return AccessLease(url: root.url, rootID: root.id)
    }
    func release(_ lease: AccessLease) { }
}

private actor P303WarmCache: ThumbnailCaching {
    private(set) var lookups = 0
    func prepare(_ request: ImageDecodeRequest) -> ThumbnailCacheTicket? {
        guard let render = request.renderKey else { return nil }
        let sha = String(repeating: "a", count: 64)
        guard let key = DurableThumbnailKey(renderKey: render, sourceSHA256: sha) else { return nil }
        return ThumbnailCacheTicket(request: request, key: key, sourceSHA256: sha)
    }
    func load(_ ticket: ThumbnailCacheTicket) -> DecodedImage? {
        lookups += 1
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: ticket.request.renderKey?.revision, itemID: ticket.request.renderKey?.itemID)
    }
    func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) { }
}

private struct P303WarmPipeline: ThumbnailCacheProviding {
    let thumbnailCache: (any ThumbnailCaching)?
    let base: P303BoundaryPipeline
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        await base.request(for: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await base.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        await base.image(for: request)
    }
    func imageFresh(for request: ImageDecodeRequest) async throws -> DecodedImage {
        await base.imageFresh(for: request)
    }
}

@Test(.timeLimit(.minutes(2))) func p303DisplayedSourceDeniedOnReacquireCannotReadWarmCache() async throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp"))
    let access = P303DenyReacquire(root: root)
    let cache = P303WarmCache()
    let base = P303BoundaryPipeline()
    let pipeline = P303WarmPipeline(thumbnailCache: cache, base: base)
    let source = try await AccessImageSource.open(.root(root.id, file: root.url.appendingPathComponent("image.png")),
        access: access, pipeline: pipeline)
    await #expect(throws: FileAccessError.startFailed) { try await source.image(maximumPixelSize: 128) }
    #expect(await cache.lookups == 0)
    #expect(await base.decodeCalls == 0)
    await source.close()
}
