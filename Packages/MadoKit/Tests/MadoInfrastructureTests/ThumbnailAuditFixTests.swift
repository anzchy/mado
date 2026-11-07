import CoreGraphics
import Foundation
import ImageIO
@testable import MadoApplication
import MadoCore
import Testing
import UniformTypeIdentifiers
@testable import MadoInfrastructure

private func auditSolidTIFF(_ url: URL, red: CGFloat) throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
        bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

private final class AuditHeldDecoder: ImageDecoding, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    let release = TestGate()

    init() { (started, signal) = AsyncStream.makeStream() }

    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        signal.yield(())
        release.wait()
        return try ImageIODecoder().decode(request)
    }
}

private final class AuditReplaceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didReplace = false
    func run(_ action: () throws -> Void) throws {
        let replace = lock.withLock { () -> Bool in
            if didReplace { return false }
            didReplace = true
            return true
        }
        if replace { try action() }
    }
}

@Test func p303StoreSourceReplacementPropagatesSourceChangedBeforeDelivery() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    try auditSolidTIFF(file, red: 1)
    try auditSolidTIFF(replacement, red: 0)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303-fix")
    let root = try await access.grant(folder: folder)
    let cacheDirectory = folder.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheDirectory, afterPayloadWrite: {
        try Data(contentsOf: replacement).write(to: file, options: .atomic)
    })
    let pipeline = ImageIOPipeline(thumbnailCache: cache)
    let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
    do {
        _ = try await source.image(maximumPixelSize: 64)
        Issue.record("decoded pixels from replaced source were delivered")
    } catch let error as ImageLoadError {
        #expect(error.kind == .sourceChanged)
    }
    await source.close()
    let counts = scope.counts
    #expect(counts[0] == counts[1])
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("index.sqlite3").path))
}

@Test(.timeLimit(.minutes(2))) func p303EligibleInFlightCancellationHoldsLeaseUntilDecodeExits() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    try auditSolidTIFF(file, red: 1)
    let cacheDirectory = folder.appendingPathComponent("cache")
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303-fix")
    let root = try await access.grant(folder: folder)
    let decoder = AuditHeldDecoder()
    defer { decoder.release.open() }
    let pipeline = ImageIOPipeline(decoder: decoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
    let work = Task { try await source.image(maximumPixelSize: 64) }
    var started = decoder.started.makeAsyncIterator()
    _ = await started.next()
    let heldCounts = scope.counts
    #expect(heldCounts[0] > heldCounts[1])
    work.cancel()
    await source.close()
    #expect(scope.counts[0] > scope.counts[1])
    decoder.release.signal()
    do {
        _ = try await work.value
        Issue.record("cancelled eligible decode delivered pixels")
    } catch let error as ImageLoadError {
        #expect(error.kind == .cancelled)
    } catch {
        #expect(error is CancellationError)
    }
    #expect(scope.counts[0] == scope.counts[1])
    let independent = ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    let freshRequest = try await independent.request(for: file, maximumPixelSize: 64,
        identityRoot: ItemIdentityRoot(id: root, url: folder))
    let ticket = try #require(try await ThumbnailDiskCache(directory: cacheDirectory).prepare(freshRequest))
    #expect(try await ThumbnailDiskCache(directory: cacheDirectory).load(ticket).map { _ in true } == nil)
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("index.sqlite3").path))
}

// Real TIFF writes, ImageIO, and SQLite can queue behind other suite tests on a loaded CI host.
@MainActor @Test(.timeLimit(.minutes(3))) func p303ViewerRetriesSourceChangedStoreWithoutInstallingOldPixels() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    try auditSolidTIFF(file, red: 1)
    try auditSolidTIFF(replacement, red: 0)
    let oldPixels = try rgba(ImageIODecoder().decode(ImageDecodeRequest(fileURL: file, maximumPixelSize: 64)).image)
    let newPixels = try rgba(ImageIODecoder().decode(ImageDecodeRequest(fileURL: replacement, maximumPixelSize: 64)).image)
    #expect(oldPixels != newPixels)
    let once = AuditReplaceOnce()
    let cache = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"), afterPayloadWrite: {
        try once.run { try Data(contentsOf: replacement).write(to: file, options: .atomic) }
    })
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303-fix")
    let root = try await access.grant(folder: folder)
    let pipeline = ImageIOPipeline(thumbnailCache: cache)
    let session = ViewerSession(), host = CacheHost()
    session.imageLoader.host = host
    session.openImage(file, maximumPixelSize: 64) {
        try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .settled)
    #expect(!host.images.isEmpty)
    #expect(try host.images.allSatisfy { try rgba($0) == newPixels })
    #expect(try host.images.allSatisfy { try rgba($0) != oldPixels })
    session.imageLoader.close()
}

@Test func p303DiskWriteFailureStillDeliversCurrentDecodedPixels() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    try auditSolidTIFF(file, red: 1)
    let expected = try rgba(ImageIODecoder().decode(ImageDecodeRequest(fileURL: file, maximumPixelSize: 64)).image)
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cacheDirectory.appendingPathComponent("index.sqlite3"),
        withIntermediateDirectories: true)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303-fix")
    let root = try await access.grant(folder: folder)
    let source = try await AccessImageSource.open(.root(root, file: file), access: access,
        pipeline: ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory)))
    let (_, delivered) = try await source.image(maximumPixelSize: 64)
    #expect(try rgba(delivered.image) == expected)
    await source.close()
    #expect(scope.counts[0] == scope.counts[1])
}

@Test func p303FreshAdmissionDoesNotJoinSameSessionKeyInFlight() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4),
        executor: executor, decoder: TinyDecoder())
    let key = decodeKey(107)
    let old = await admission.subscribe(tinyRequest, key: key, cost: 4, heavy: false, priority: .current)
    let fresh = await admission.subscribe(tinyRequest, key: key, cost: 4, heavy: false,
        priority: .current, reuseExisting: false)
    #expect(executor.count == 1)
    #expect(await admission.activity().waiting == 1)
    executor.runFirst()
    _ = try await old.value()
    #expect(executor.count == 1)
    executor.runFirst()
    _ = try await fresh.value()
    #expect(await admission.activity().running == 0)
}

@Test func p303FreshDecodeRejectsPrecancelChangedRequestAndSuspendedPrefetch() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    try auditSolidTIFF(file, red: 1)
    try auditSolidTIFF(replacement, red: 0)
    let pipeline = ImageIOPipeline()
    let old = try await pipeline.request(for: file, maximumPixelSize: 64)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await pipeline.imageFresh(for: old)
    }
    do { _ = try await cancelled.value; Issue.record("pre-cancelled fresh decode delivered pixels") }
    catch let error as ImageLoadError { #expect(error.kind == .cancelled) }
    try Data(contentsOf: replacement).write(to: file, options: .atomic)
    do { _ = try await pipeline.imageFresh(for: old); Issue.record("stale request decoded changed source") }
    catch let error as ImageLoadError { #expect(error.kind == .sourceChanged) }
    let current = try await pipeline.request(for: file, maximumPixelSize: 64)
    let prefetch = ImageDecodeRequest(fileURL: file, maximumPixelSize: 64, renderKey: current.renderKey,
        priority: .prefetch)
    await pipeline.memoryPressure(.warning)
    do { _ = try await pipeline.imageFresh(for: prefetch); Issue.record("suspended prefetch decoded") }
    catch let error as ImageLoadError { #expect(error.kind == .cancelled) }
}

private final class AuditRewritingDecoder: ImageDecoding, @unchecked Sendable {
    let replacement: URL
    let file: URL
    init(replacement: URL, file: URL) { self.replacement = replacement; self.file = file }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let image = try ImageIODecoder().decode(request)
        try Data(contentsOf: replacement).write(to: file, options: .atomic)
        return image
    }
}

@Test func p303FreshDecodeRejectsRevisionChangedInsideDecoder() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    try auditSolidTIFF(file, red: 1)
    try auditSolidTIFF(replacement, red: 0)
    let pipeline = ImageIOPipeline(decoder: AuditRewritingDecoder(replacement: replacement, file: file))
    let request = try await pipeline.request(for: file, maximumPixelSize: 64)
    do { _ = try await pipeline.imageFresh(for: request); Issue.record("changed decode revision delivered") }
    catch let error as ImageLoadError { #expect(error.kind == .sourceChanged) }
}

@Test func p303StoreRejectsMismatchedDecodedIdentity() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    try auditSolidTIFF(file, red: 1)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"))
    let ticket = try #require(try await cache.prepare(request))
    let wrong = DecodedImage(image: decoded.image, sourcePixelSize: decoded.sourcePixelSize,
        formatIdentifier: decoded.formatIdentifier, revision: FileRevision(byteCount: 999, modificationDate: nil),
        itemID: decoded.itemID)
    do { try await cache.store(wrong, for: ticket); Issue.record("wrong decoded revision accepted") }
    catch let error as ImageLoadError { #expect(error.kind == .sourceChanged) }
}

@Test func p303PostwriteCancellationRemovesUnindexedPayload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    try auditSolidTIFF(file, red: 1)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cacheDirectory = folder.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheDirectory, afterPayloadWrite: {
        withUnsafeCurrentTask { $0?.cancel() }
    })
    let ticket = try #require(try await cache.prepare(request))
    let work = Task { try await cache.store(decoded, for: ticket) }
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png").path))
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("index.sqlite3").path))
}

@Test func p303PostwriteSourceLossPropagatesAndRemovesPayload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    try auditSolidTIFF(file, red: 1)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cacheDirectory = folder.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheDirectory, afterPayloadWrite: {
        try FileManager.default.removeItem(at: file)
    })
    let ticket = try #require(try await cache.prepare(request))
    do { try await cache.store(decoded, for: ticket); Issue.record("lost source was accepted") }
    catch let error as ImageLoadError { #expect(error.kind == .sourceChanged) }
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png").path))
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("index.sqlite3").path))
}

@Test func p303LegacyEncoderTicketCannotBeLoadedOrStored() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    try auditSolidTIFF(file, red: 1)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 64, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cacheDirectory = folder.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let current = try #require(try await cache.prepare(request))
    let render = try #require(request.renderKey)
    let oldKey = try #require(DurableThumbnailKey(renderKey: render,
        sourceSHA256: current.sourceSHA256, encoderVersion: 1))
    #expect(oldKey.filename != current.key.filename)
    let legacy = ThumbnailCacheTicket(request: request, key: oldKey, sourceSHA256: current.sourceSHA256)
    try await cache.store(decoded, for: legacy)
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    #expect(try await cache.load(legacy).map { _ in true } == nil)
}
