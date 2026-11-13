import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoApplication
import MadoCore
@testable import MadoInfrastructure

private final class P303CountingDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        lock.withLock { value += 1 }
        return try ImageIODecoder().decode(request)
    }
}

private func p303SolidTIFF(_ url: URL, red: CGFloat) throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
        bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test(.timeLimit(.minutes(2))) func p303AccessSourceReopensFromDiskButDeniedAccessAndPublicPipelineDoNotHit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.png")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: file)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
                                store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303")
    let root = try await access.grant(folder: folder)
    let firstDecoder = P303CountingDecoder()
    let firstPipeline = ImageIOPipeline(decoder: firstDecoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    let first = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: firstPipeline)
    let (_, firstImage) = try await first.image(maximumPixelSize: 128)
    await first.close()
    #expect(firstDecoder.count == 1)

    let reopenedDecoder = P303CountingDecoder()
    let reopenedPipeline = ImageIOPipeline(decoder: reopenedDecoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    let reopened = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: reopenedPipeline)
    let (_, hit) = try await reopened.image(maximumPixelSize: 128)
    await reopened.close()
    #expect(try rgba(hit.image) == rgba(firstImage.image))
    #expect(reopenedDecoder.count == 0)

    scope.succeeds = false
    await #expect(throws: FileAccessError.startFailed) {
        try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: reopenedPipeline)
    }
    #expect(reopenedDecoder.count == 0)
    let direct = try await reopenedPipeline.request(for: file, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: root, url: folder))
    _ = try await reopenedPipeline.image(for: direct)
    #expect(reopenedDecoder.count == 1)
}

@Test(.timeLimit(.minutes(2))) func p303AccessSourceSameSizeSameTimeReplacementDecodesNewPixels() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try p303SolidTIFF(file, red: 1)
    try p303SolidTIFF(replacement, red: 0)
    #expect(try Data(contentsOf: file).count == Data(contentsOf: replacement).count)
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
                                store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303")
    let root = try await access.grant(folder: folder)
    let firstDecoder = P303CountingDecoder()
    let first = try await AccessImageSource.open(.root(root, file: file), access: access,
        pipeline: ImageIOPipeline(decoder: firstDecoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory)))
    let (_, old) = try await first.image(maximumPixelSize: 64)
    await first.close()
    #expect(firstDecoder.count == 1)
    try Data(contentsOf: replacement).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    let secondDecoder = P303CountingDecoder()
    let second = try await AccessImageSource.open(.root(root, file: file), access: access,
        pipeline: ImageIOPipeline(decoder: secondDecoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory)))
    let (_, fresh) = try await second.image(maximumPixelSize: 64)
    await second.close()
    #expect(secondDecoder.count == 1)
    #expect(try rgba(old.image) != rgba(fresh.image))
}

@Test(.timeLimit(.minutes(2))) func p303FileGrantNeverCreatesPersistentThumbnail() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.png")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: file)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
                                store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303")
    let source = try await AccessImageSource.open(.fileGrant(file), access: access,
        pipeline: ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory)))
    _ = try await source.image(maximumPixelSize: 128)
    await source.close()
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
}

@Test(.timeLimit(.minutes(2))) func p303InPlaceSameRevisionChangeNeverPersistsWarmMemoryPixels() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try p303SolidTIFF(file, red: 1)
    try p303SolidTIFF(replacement, red: 0)
    let blueBytes = try Data(contentsOf: replacement)
    #expect(try Data(contentsOf: file).count == blueBytes.count)
    let time = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    let originalRevision = try FileRevisionReader.read(file)
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303-fix")
    let root = try await access.grant(folder: folder)
    let decoder = P303CountingDecoder()
    let pipeline = ImageIOPipeline(decoder: decoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    let first = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
    let (_, imageA) = try await first.image(maximumPixelSize: 64)
    await first.close()
    #expect(decoder.count == 1)

    try blueBytes.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    #expect(try FileRevisionReader.read(file) == originalRevision)
    let expectedB = try ImageIODecoder().decode(ImageDecodeRequest(fileURL: file, maximumPixelSize: 64))
    #expect(try rgba(imageA.image) != rgba(expectedB.image))
    let second = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
    let (_, imageB) = try await second.image(maximumPixelSize: 64)
    await second.close()
    #expect(try rgba(imageB.image) == rgba(expectedB.image))
    #expect(decoder.count == 2)

    let restartDecoder = P303CountingDecoder()
    let restartPipeline = ImageIOPipeline(decoder: restartDecoder,
        thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    let restarted = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: restartPipeline)
    let (_, durableB) = try await restarted.image(maximumPixelSize: 64)
    await restarted.close()
    #expect(try rgba(durableB.image) == rgba(expectedB.image))
    #expect(restartDecoder.count == 0)
}

private final class P303HeldAfterDecode: ImageDecoding, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    let release = TestGate()
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    init() { (started, signal) = AsyncStream.makeStream() }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let decoded = try ImageIODecoder().decode(request)
        let first = lock.withLock { () -> Bool in
            calls += 1
            return calls == 1
        }
        if first {
            signal.yield(())
            release.wait()
        }
        return decoded
    }
}

private actor P303ChangedTicketSignalCache: ThumbnailCaching {
    let base: ThumbnailDiskCache
    let changed: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var firstDigest: String?
    init(directory: URL) {
        base = ThumbnailDiskCache(directory: directory)
        (changed, signal) = AsyncStream.makeStream()
    }
    func prepare(_ request: ImageDecodeRequest) async throws -> ThumbnailCacheTicket? {
        let ticket = try await base.prepare(request)
        if let ticket {
            if let firstDigest {
                if ticket.sourceSHA256 != firstDigest { signal.yield(()) }
            } else { firstDigest = ticket.sourceSHA256 }
        }
        return ticket
    }
    func load(_ ticket: ThumbnailCacheTicket) async throws -> DecodedImage? { try await base.load(ticket) }
    func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async throws {
        try await base.store(image, for: ticket)
    }
}

@Test(.timeLimit(.minutes(2))) func p303HeldOldDecodeCannotJoinNewDurableTicketOrPersistOldPixels() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let replacement = folder.appendingPathComponent("replacement.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try p303SolidTIFF(file, red: 1)
    try p303SolidTIFF(replacement, red: 0)
    let blueBytes = try Data(contentsOf: replacement)
    #expect(try Data(contentsOf: file).count == blueBytes.count)
    let time = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    let revision = try FileRevisionReader.read(file)
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303-fix")
    let root = try await access.grant(folder: folder)
    let decoder = P303HeldAfterDecode()
    defer { decoder.release.open() }
    let cache = P303ChangedTicketSignalCache(directory: cacheDirectory)
    let pipeline = ImageIOPipeline(decoder: decoder, thumbnailCache: cache)
    let started = StartedTasks()
    try await withAsyncTeardown {
        let oldSource = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
        let oldWork = started.track(Task { try await oldSource.image(maximumPixelSize: 64) })
        var decoding = decoder.started.makeAsyncIterator()
        _ = await decoding.next()
        try blueBytes.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
        #expect(try FileRevisionReader.read(file) == revision)
        let expectedB = try ImageIODecoder().decode(ImageDecodeRequest(fileURL: file, maximumPixelSize: 64))
        let newSource = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
        let newWork = started.track(Task { try await newSource.image(maximumPixelSize: 64) })
        var changed = cache.changed.makeAsyncIterator()
        _ = await changed.next() // B's durable ticket was prepared while A remains held.
        decoder.release.signal()
        do { _ = try await oldWork.value; Issue.record("old decoded pixels delivered after B replaced A") }
        catch let error as ImageLoadError { #expect(error.kind == .sourceChanged) }
        let (_, newImage) = try await newWork.value
        #expect(try rgba(newImage.image) == rgba(expectedB.image))
        #expect(decoder.count == 2)
        await oldSource.close()
        await newSource.close()
        let restartDecoder = P303CountingDecoder()
        let reopened = try await AccessImageSource.open(.root(root, file: file), access: access,
            pipeline: ImageIOPipeline(decoder: restartDecoder, thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory)))
        let (_, durableB) = try await reopened.image(maximumPixelSize: 64)
        await reopened.close()
        #expect(try rgba(durableB.image) == rgba(expectedB.image))
        #expect(restartDecoder.count == 0)
    } teardown: {
        started.cancelAll(); decoder.release.open()
        await started.awaitAll()
    }
}
