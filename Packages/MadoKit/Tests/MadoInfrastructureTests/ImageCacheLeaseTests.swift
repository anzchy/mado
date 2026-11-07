import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoInfrastructure

final class CacheEvents: ResourceSnapshotTracing, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
    func reset() { lock.withLock { events.removeAll() } }
    func lookup(isPreview: Bool, hit: Bool) { append("lookup(\(hit ? "hit" : "miss"))") }
}

actor CacheLeases: AccessLeasing {
    let events: CacheEvents
    let rootURL: URL?
    private(set) var active: Set<AccessLease> = []
    private(set) var acquired: [AccessLease] = [], released: [AccessLease] = []
    private var attempts = 0
    private var refused: Int?
    private var drained: [CheckedContinuation<Void, Never>] = []
    init(events: CacheEvents = CacheEvents(), rootURL: URL? = nil) { self.events = events; self.rootURL = rootURL }
    func refuseAcquire(after successful: Int) { refused = attempts + successful + 1 }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        attempts += 1
        let role = active.isEmpty ? "display" : "decode"
        if attempts == refused {
            events.append("acquire(\(role),refused)")
            throw FileAccessError.startFailed
        }
        let lease: AccessLease
        switch request {
        case .fileGrant(let file): lease = AccessLease(url: file, rootID: nil)
        case .root(let id, let file): lease = AccessLease(url: rootURL ?? file.deletingLastPathComponent(), rootID: id)
        }
        events.append("acquire(\(role))")
        active.insert(lease); acquired.append(lease)
        return lease
    }
    func release(_ lease: AccessLease) {
        active.remove(lease); released.append(lease)
        events.append("release(\(active.isEmpty ? "display" : "decode"))")
        if active.isEmpty { let waiting = drained; drained.removeAll(); for waiter in waiting { waiter.resume() } }
    }
    func waitUntilEmpty() async {
        if !active.isEmpty { await withCheckedContinuation { drained.append($0) } }
    }
}

final class CacheCountingDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String: Int] = [:]
    let events: CacheEvents?
    init(events: CacheEvents? = nil) { self.events = events }
    var counts: [String: Int] { lock.withLock { runs } }
    var count: Int { lock.withLock { runs.values.reduce(0, +) } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let tier = request.isPreview ? "preview" : "detail"
        lock.withLock { runs[request.fileURL.lastPathComponent + "/" + tier, default: 0] += 1 }
        events?.append("decode")
        return try ImageIODecoder().decode(request)
    }
}

struct CachePipelineEvents: ImagePipeline {
    let pipeline: ImageIOPipeline
    let events: CacheEvents
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: nil)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        events.append("pipeline.request")
        return try await pipeline.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        events.append("pipeline.image")
        return try await pipeline.image(for: request)
    }
}

@MainActor final class CacheHost: ViewerImageHost {
    var names: [String] = [], images: [CGImage] = []
    var failures: [any Error] = []
    func beginImageOpening() { }
    func installImage(_ image: DecodedImage, fileURL: URL) { names.append(fileURL.lastPathComponent); images.append(image.image) }
    func imageLoadFailed(_ error: any Error) { failures.append(error) }
}

@Suite struct ImageCacheLeaseTests {
    @Test func cacheLeaseOrderOnMissAndHit() async throws {
        let events = CacheEvents(), decoder = CacheCountingDecoder(events: events)
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let actual = ImageIOPipeline(decoder: decoder, cache: cache, cacheTrace: events)
        let pipeline = CachePipelineEvents(pipeline: actual, events: events), access = CacheLeases(events: events)
        let file = fixture("coordinate-grid.png")
        let first = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
        let (coldRequest, cold) = try await first.image(maximumPixelSize: 16)
        #expect(events.values == ["acquire(display)", "acquire(decode)", "pipeline.request", "pipeline.image", "lookup(miss)", "decode", "release(decode)"])
        #expect(cold.image.width == 16 && cold.image.height == 12)
        #expect(cold.itemID == coldRequest.renderKey?.itemID && cold.revision == coldRequest.renderKey?.revision)
        await first.close(); events.reset()
        let second = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
        let (_, warm) = try await second.image(maximumPixelSize: 16)
        #expect(events.values == ["acquire(display)", "acquire(decode)", "pipeline.request", "pipeline.image", "lookup(hit)", "release(decode)"])
        #expect(warm.image === cold.image)
        #expect(decoder.count == 1)
        await second.close()
        #expect(await access.active.isEmpty)
        let acquired = await access.acquired, released = await access.released
        #expect(acquired.count == 4 && released.count == 4)
        for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
    }

    @MainActor @Test(arguments: [false, true], [0, 1]) func cacheRevokedDisplayAndDecodeLeaseDeliverNothing(root: Bool, successfulAcquires: Int) async throws {
        let file = fixture("coordinate-grid.png"), events = CacheEvents(), decoder = CacheCountingDecoder()
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let actual = ImageIOPipeline(decoder: decoder, cache: cache, cacheTrace: events)
        let pipeline = CachePipelineEvents(pipeline: actual, events: events)
        let access = CacheLeases(events: events, rootURL: file.deletingLastPathComponent())
        let request: AccessRequest = root ? .root(AccessRootID(), file: file) : .fileGrant(file)
        let seed = try await AccessImageSource.open(request, access: access, pipeline: pipeline)
        _ = try await seed.image(maximumPixelSize: 16)
        await seed.close()
        #expect(await cache.usage().entries == 1)
        let count = decoder.count
        events.reset(); await access.refuseAcquire(after: successfulAcquires)
        let session = ViewerSession(), host = CacheHost()
        session.imageLoader.host = host
        session.openImage(file, maximumPixelSize: 16) { try await AccessImageSource.open(request, access: access, pipeline: pipeline) }
        await session.imageLoader.loadTask?.value
        #expect(session.imageLoader.phase == .failed)
        #expect(session.imageLoader.failure as? FileAccessError == .startFailed)
        #expect(host.images.isEmpty && host.failures.count == 1)
        #expect(!events.values.contains { $0.hasPrefix("lookup") })
        #expect(decoder.count == count)
        if successfulAcquires == 0 { #expect(events.values == ["acquire(display,refused)"]) }
        else { #expect(events.values == ["acquire(display)", "acquire(decode,refused)", "release(display)"]) }
        #expect(await access.active.isEmpty)
        let acquired = await access.acquired, released = await access.released
        for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
    }
}
