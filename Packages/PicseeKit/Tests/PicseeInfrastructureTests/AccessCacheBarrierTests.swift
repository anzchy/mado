import Foundation
import Testing
import PicseeCore
@testable import PicseeInfrastructure

private actor T229CachePause {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

private func t229Request(_ original: ImageDecodeRequest, permit: AccessWorkPermit) -> ImageDecodeRequest {
    ImageDecodeRequest(fileURL: original.fileURL, maximumPixelSize: original.maximumPixelSize,
        renderKey: original.renderKey, identityRoot: original.identityRoot, accessPermit: permit)
}

@Test func t229MemoryCacheCannotRetainHeldDecodeAfterCounterChanges() async throws {
    let authority = AccessWorkAuthority()
    authority.update(counter: 0, readable: true)
    let decoder = CacheBlockingDecoder(), memory = ImageMemoryCache(capacity: 1_000_000)
    defer { decoder.gate.open() }
    let pipeline = ImageIOPipeline(decoder: decoder, cache: memory)
    let original = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 32)
    let request = t229Request(original, permit: authority.permit(counter: 0))
    let pending = Task { try await pipeline.image(for: request) }
    for await _ in decoder.started { break }
    authority.update(counter: 1, readable: false)
    decoder.gate.signal()
    do { _ = try await pending.value; Issue.record("revoked decode was delivered") }
    catch { #expect(error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled) }
    #expect(await memory.diagnostics().entries == 0)
    authority.update(counter: 1, readable: true)
    let fresh = t229Request(original, permit: authority.permit(counter: 1))
    _ = try await pipeline.image(for: fresh)
    #expect(decoder.count == 2)
    #expect(await memory.diagnostics().entries == 1)
    await #expect(throws: (any Error).self) { try await pipeline.image(for: request) }
}

@Test func t229DiskPublicationCannotIndexAfterCounterChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("image.tiff")
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: directory)
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let pipeline = ImageIOPipeline()
    let raw = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let request = t229Request(raw, permit: authority.permit(counter: 0))
    let image = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"), afterPayloadWrite: {
        authority.update(counter: 1, readable: false)
    })
    let ticket = try #require(try await cache.prepare(request))
    await #expect(throws: CancellationError.self) { try await cache.store(image, for: ticket) }
    #expect(await cache.diagnostics().entries == 0)
    #expect(await cache.writeDiagnostics().failureCount == 0)
}

@Test(.timeLimit(.minutes(3))) func t229DiskHeldHitIsRejectedButRetainedPayloadCanBeRevalidated() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("image.tiff")
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: directory)
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let pipeline = ImageIOPipeline()
    let raw = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let request = t229Request(raw, permit: authority.permit(counter: 0))
    let image = try await pipeline.image(for: request)
    let path = directory.appendingPathComponent("cache")
    let writer = ThumbnailDiskCache(directory: path)
    let ticket = try #require(try await writer.prepare(request))
    try await writer.store(image, for: ticket)
    let pause = T229CachePause()
    let reader = ThumbnailDiskCache(directory: path, afterReadLeaseAcquired: { await pause.pause() })
    let pending = Task { try await reader.load(ticket) }
    while !(await pause.entered) { try Task.checkCancellation(); await Task.yield() }
    authority.update(counter: 1, readable: false)
    await pause.resume()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await reader.diagnostics().hits == 0)
    authority.update(counter: 1, readable: true)
    let freshRequest = t229Request(raw, permit: authority.permit(counter: 1))
    let fresh = try #require(try await writer.prepare(freshRequest))
    let hit = try #require(try await writer.load(fresh))
    #expect(try rgba(hit.image) == rgba(image.image))
    #expect(await writer.diagnostics().entries == 1)
}

@Test func t229WarmedMemoryOriginCannotSurviveRecovery() async throws {
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let decoder = CacheCountingDecoder(), memory = ImageMemoryCache(capacity: 1_000_000)
    let pipeline = ImageIOPipeline(decoder: decoder, cache: memory)
    let raw = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 32)
    let old = t229Request(raw, permit: authority.permit(counter: 0))
    _ = try await pipeline.image(for: old)
    #expect(decoder.count == 1)
    authority.update(counter: 1, readable: false)
    authority.update(counter: 1, readable: true)
    let recovered = t229Request(raw, permit: authority.permit(counter: 1))
    _ = try await pipeline.image(for: recovered)
    #expect(decoder.count == 2)
    #expect(await memory.diagnostics().entries == 1)
    _ = try await pipeline.image(for: recovered)
    #expect(decoder.count == 2)
}

@Test func t229LossDuringRewritePreservesExistingDurablePayload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("image.tiff")
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: directory)
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let pipeline = ImageIOPipeline()
    let raw = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let request = t229Request(raw, permit: authority.permit(counter: 0))
    let image = try await pipeline.image(for: request)
    let path = directory.appendingPathComponent("cache")
    let original = ThumbnailDiskCache(directory: path)
    let ticket = try #require(try await original.prepare(request))
    try await original.store(image, for: ticket)
    let rewriting = ThumbnailDiskCache(directory: path, afterPayloadWrite: {
        authority.update(counter: 1, readable: false)
    })
    await #expect(throws: CancellationError.self) { try await rewriting.store(image, for: ticket) }
    authority.update(counter: 1, readable: true)
    let recovered = ThumbnailDiskCache(directory: path)
    let fresh = try #require(try await recovered.prepare(t229Request(raw, permit: authority.permit(counter: 1))))
    let hit = try #require(try await recovered.load(fresh))
    #expect(try rgba(hit.image) == rgba(image.image))
    #expect(await recovered.diagnostics().entries == 1)
}

private final class T229RevocationWorker: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let requested = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    let authority: AccessWorkAuthority
    init(_ authority: AccessWorkAuthority) { self.authority = authority }
    func run() {
        ready.signal()
        while true {
            requested.wait()
            if lock.withLock({ stopped }) { return }
            authority.update(counter: 1, readable: false)
            completed.signal()
        }
    }
    func stop() { lock.withLock { stopped = true }; requested.signal() }
}

private final class T229RevokingTrace: ResourceSnapshotTracing, @unchecked Sendable {
    private let worker: T229RevocationWorker
    private let thread: Thread
    private let lock = NSLock()
    private var observations: [Bool] = []
    private var cancelled = false
    init(_ authority: AccessWorkAuthority) {
        let worker = T229RevocationWorker(authority)
        self.worker = worker
        thread = Thread { worker.run() }
        thread.name = "picsee.test.access-revocation"
        thread.start()
        // Await the dedicated worker's startup before requesting revocation.
        worker.ready.wait()
    }
    deinit { worker.stop() }
    var admittedRevocationDuringCallback: Bool { lock.withLock { !observations.isEmpty && observations.allSatisfy { $0 } } }
    func lookup(isPreview: Bool, hit: Bool) {}
    func cancel() {
        lock.withLock { cancelled = true }
        // Unblock even a lock-order regression when the enclosing test expires.
        // Cancellation is recorded as failure, never as successful revocation.
        worker.completed.signal()
    }
    func snapshot(_ snapshot: ResourceSnapshot) {
        guard lock.withLock({ !cancelled }) else {
            lock.withLock { observations.append(false) }
            return
        }
        worker.requested.signal()
        worker.completed.wait()
        lock.withLock { observations.append(!cancelled) }
    }
}

@Test(.timeLimit(.minutes(3))) func t229MemoryPublicationReleasesAuthorityBeforeTracing() async throws {
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let permit = authority.permit(counter: 0), cache = ImageMemoryCache(capacity: 1024)
    let key = cacheKey(229)
    let request = await cache.lookup(key)
    let trace = T229RevokingTrace(authority)
    let context = ResourceSnapshotContext(tracer: trace,
        activity: DecodeActivity(running: 0, nonCurrent: 0, visible: 0, heavy: 0, reservedBytes: 0, waiting: 0))
    let image = cacheImage(try cachePixels(), key: key)
    await withTaskCancellationHandler {
        _ = await cache.finish(request, image: image, context: context, accessPermit: permit)
    } onCancel: {
        trace.cancel()
    }
    #expect(trace.admittedRevocationDuringCallback)
    #expect(!permit.isCurrent)
    #expect(await cache.image(for: key) == nil)
}

@Test func t229RealSourceFingerprintPermissionIsNotACacheMiss() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("image.tiff")
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: directory)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    let cache = ThumbnailDiskCache(directory: directory.appendingPathComponent("cache"))
    do { _ = try await cache.prepare(request); Issue.record("source permission refusal became a cache miss") }
    catch { #expect(AccessReadFailure.isPermissionDenied(error)) }
}

private func t229Tag(_ image: DecodedImage, permit: AccessWorkPermit) -> DecodedImage {
    DecodedImage(image: image.image, sourcePixelSize: image.sourcePixelSize,
        formatIdentifier: image.formatIdentifier, revision: image.revision, itemID: image.itemID, accessPermit: permit)
}

@Test func t229HeldPinCannotReinsertRevokedPixels() async throws {
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let permit = authority.permit(counter: 0), memory = ImageMemoryCache(capacity: 1024)
    let key = cacheKey(230), image = t229Tag(cacheImage(try cachePixels(), key: key), permit: permit)
    authority.update(counter: 1, readable: false)
    await memory.pin(key, image: image)
    #expect(await memory.pinCount(for: key) == 0)
    #expect(await memory.image(for: key) == nil)
}

@Test func t229PinnedDurablePixelsCannotWarmLaterCacheDisabledRequest() async throws {
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let permit = authority.permit(counter: 0), memory = ImageMemoryCache(capacity: 1_000_000)
    let decoder = CacheCountingDecoder()
    let pipeline = ImageIOPipeline(decoder: decoder, cache: memory)
    let raw = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 32)
    let old = t229Request(raw, permit: permit)
    let decoded = try await pipeline.imageFresh(for: old)
    let key = try #require(old.renderKey)
    await memory.pin(key, image: t229Tag(decoded, permit: permit))
    await memory.unpin(key)
    #expect(decoder.count == 1)
    authority.update(counter: 1, readable: false)
    authority.update(counter: 1, readable: true)
    // Normal image() is the path used when durable caching is unavailable.
    let fresh = t229Request(raw, permit: authority.permit(counter: 1))
    _ = try await pipeline.image(for: fresh)
    #expect(decoder.count == 2)
    #expect(await memory.diagnostics().entries == 1)
}

@Test func t229FreshCounterQueuesOwnDecodeInsteadOfJoiningRevokedJob() async throws {
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let decoder = CacheBlockingDecoder(), pipeline = ImageIOPipeline(decoder: decoder)
    defer { decoder.gate.open() }
    let raw = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 32)
    let key = try #require(raw.renderKey)
    let old = await pipeline.admission.subscribe(t229Request(raw, permit: authority.permit(counter: 0)),
        key: key, cost: 4096, heavy: false, priority: .current)
    for await _ in decoder.started { break }
    authority.update(counter: 1, readable: false)
    authority.update(counter: 1, readable: true)
    let fresh = await pipeline.admission.subscribe(t229Request(raw, permit: authority.permit(counter: 1)),
        key: key, cost: 4096, heavy: false, priority: .current)
    #expect(await pipeline.admission.activity().waiting == 1)
    decoder.gate.signal()
    await #expect(throws: CancellationError.self) { try await old.value() }
    let image = try await fresh.value()
    #expect(image.itemID == key.itemID && image.revision == key.revision)
    #expect(decoder.count == 2)
}

@Test func t229SameCounterRetainsDecodeCoalescence() async throws {
    let authority = AccessWorkAuthority(); authority.update(counter: 0, readable: true)
    let decoder = CacheBlockingDecoder(), pipeline = ImageIOPipeline(decoder: decoder)
    defer { decoder.gate.open() }
    let raw = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 32)
    let key = try #require(raw.renderKey)
    let first = await pipeline.admission.subscribe(t229Request(raw, permit: authority.permit(counter: 0)),
        key: key, cost: 4096, heavy: false, priority: .current)
    for await _ in decoder.started { break }
    let second = await pipeline.admission.subscribe(t229Request(raw, permit: authority.permit(counter: 0)),
        key: key, cost: 4096, heavy: false, priority: .current)
    #expect(await pipeline.admission.activity().waiting == 0)
    decoder.gate.signal()
    let a = try await first.value(), b = try await second.value()
    #expect(a.image === b.image)
    #expect(decoder.count == 1)
}

@Test func t229CoalescenceRequiresSameAuthorityAndCounter() {
    let a = AccessWorkAuthority(), b = AccessWorkAuthority()
    let old = a.permit(counter: 0), same = a.permit(counter: 0)
    let fresh = a.permit(counter: 1), other = b.permit(counter: 0)
    #expect(old.canCoalesce(with: same))
    #expect(!old.canCoalesce(with: fresh))
    #expect(!old.canCoalesce(with: other))
    #expect(!old.canCoalesce(with: nil))
}
