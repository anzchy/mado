import Foundation
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoInfrastructure

private actor CacheDeliveryGate {
    let arrivals: AsyncStream<String>
    private let signal: AsyncStream<String>.Continuation
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    init() { (arrivals, signal) = AsyncStream.makeStream() }
    func hold(_ file: URL) async {
        let name = file.lastPathComponent
        guard name == "coordinate-grid.png" || name == "landscape-3x2.png" else { return }
        await withCheckedContinuation { waiting[name] = $0; signal.yield(name) }
    }
    func release(_ name: String) { waiting.removeValue(forKey: name)?.resume() }
}

private struct CacheDelayedPipeline: ImagePipeline {
    let pipeline: ImageIOPipeline
    let gate: CacheDeliveryGate
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await pipeline.request(for: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await pipeline.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        let result = try await pipeline.image(for: request)
        await gate.hold(request.fileURL)
        return result
    }
}

@Suite @MainActor struct ImageCacheSessionTests {
    @Test(.timeLimit(.minutes(2))) func cacheWarmXtoYtoXAndSecondSession() async throws {
        let decoder = CacheCountingDecoder(), cache = ImageMemoryCache(capacity: 16_000_000)
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache), access = CacheLeases()
        let a = ViewerSession(), b = ViewerSession(), ah = CacheHost(), bh = CacheHost()
        a.imageLoader.host = ah; b.imageLoader.host = bh
        let x = fixture("coordinate-grid.png"), y = fixture("landscape-3x2.png")
        for file in [x, y, x] {
            a.openImage(file, maximumPixelSize: 128) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
            await a.imageLoader.loadTask?.value
            #expect(a.imageLoader.phase == .settled)
            #expect(a.imageLoader.presented?.name == file.lastPathComponent)
        }
        a.closeImage(); await access.waitUntilEmpty()
        b.openImage(x, maximumPixelSize: 128) { try await AccessImageSource.open(.fileGrant(x), access: access, pipeline: pipeline) }
        await b.imageLoader.loadTask?.value
        #expect(ah.names == ["coordinate-grid.png", "coordinate-grid.png", "landscape-3x2.png", "landscape-3x2.png", "coordinate-grid.png", "coordinate-grid.png"])
        #expect(bh.names == ["coordinate-grid.png", "coordinate-grid.png"])
        #expect(decoder.counts == ["coordinate-grid.png/preview": 1, "coordinate-grid.png/detail": 1,
                                  "landscape-3x2.png/preview": 1, "landscape-3x2.png/detail": 1])
        #expect(ah.images[0] === ah.images[4] && ah.images[1] === ah.images[5])
        #expect(ah.images[0] === bh.images[0] && ah.images[1] === bh.images[1])
        #expect(await cache.usage().entries == 4)
        b.closeImage(); await access.waitUntilEmpty()
        let freshDecoder = CacheCountingDecoder(), fresh = ImageIOPipeline(decoder: freshDecoder)
        let source = try await AccessImageSource.open(.fileGrant(x), access: access, pipeline: fresh)
        _ = try await source.image(maximumPixelSize: 512, isPreview: true)
        _ = try await source.image(maximumPixelSize: 128)
        #expect(freshDecoder.count == 2)
        await source.close()
    }

    @Test(.timeLimit(.minutes(2))) func cacheCachedADelayedBehindCIsRejected() async throws {
        let decoder = CacheCountingDecoder(), cache = ImageMemoryCache(capacity: 16_000_000)
        let pipeline = ImageIOPipeline(decoder: decoder, cache: cache), access = CacheLeases()
        let session = ViewerSession(), host = CacheHost()
        session.imageLoader.host = host
        let a = fixture("coordinate-grid.png"), b = fixture("landscape-3x2.png"), c = fixture("portrait-2x3.png")
        session.openImage(a, maximumPixelSize: 128) { try await AccessImageSource.open(.fileGrant(a), access: access, pipeline: pipeline) }
        await session.imageLoader.loadTask?.value
        #expect(session.imageLoader.phase == .settled)
        #expect(decoder.count == 2)
        host.names.removeAll(); host.images.removeAll()
        let gate = CacheDeliveryGate(), delayed = CacheDelayedPipeline(pipeline: pipeline, gate: gate)
        var arrivals = gate.arrivals.makeAsyncIterator()
        session.openImage(a, maximumPixelSize: 128) { try await AccessImageSource.open(.fileGrant(a), access: access, pipeline: delayed) }
        let at = session.imageLoader.loadTask
        #expect(await arrivals.next() == "coordinate-grid.png")
        session.openImage(b, maximumPixelSize: 128) { try await AccessImageSource.open(.fileGrant(b), access: access, pipeline: delayed) }
        let bt = session.imageLoader.loadTask
        #expect(await arrivals.next() == "landscape-3x2.png")
        session.openImage(c, maximumPixelSize: 128) { try await AccessImageSource.open(.fileGrant(c), access: access, pipeline: delayed) }
        await session.imageLoader.loadTask?.value
        await gate.release("landscape-3x2.png"); await bt?.value
        await gate.release("coordinate-grid.png"); await at?.value
        #expect(host.names == ["portrait-2x3.png", "portrait-2x3.png"])
        #expect(session.imageLoader.presented?.name == "portrait-2x3.png")
        #expect(session.imageLoader.phase == .settled)
        #expect(host.failures.isEmpty)
        #expect(decoder.counts["coordinate-grid.png/preview"] == 1)
        #expect(decoder.counts["coordinate-grid.png/detail"] == 1)
        session.closeImage(); await access.waitUntilEmpty()
        let acquired = await access.acquired, released = await access.released
        #expect(acquired.count == released.count)
        for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
    }
}
