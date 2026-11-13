import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import UniformTypeIdentifiers
import MadoCore
@testable import MadoInfrastructure

@Test func p304IntegrityClassifierPreservesIndexOnUnconfirmedFailures() {
    typealias Decision = ThumbnailDiskCache.IntegrityDecision
    let classify = ThumbnailDiskCache.integrityDecision
    #expect(classify(SQLITE_BUSY, nil, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_LOCKED, nil, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_IOERR, nil, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_OK, SQLITE_BUSY, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_OK, SQLITE_LOCKED, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_OK, SQLITE_IOERR, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_CORRUPT, nil, nil) == .confirmedCorrupt)
    #expect(classify(SQLITE_NOTADB, nil, nil) == .confirmedCorrupt)
    #expect(classify(SQLITE_OK, SQLITE_CORRUPT, nil) == .confirmedCorrupt)
    #expect(classify(SQLITE_OK, SQLITE_NOTADB, nil) == .confirmedCorrupt)
    #expect(classify(SQLITE_OK, SQLITE_ROW, "ok") == .healthy)
    #expect(classify(SQLITE_OK, SQLITE_ROW, "*** in database main ***") == .confirmedCorrupt)
    #expect(classify(SQLITE_OK, SQLITE_ROW, nil) == .unconfirmedFailure)
    #expect(classify(SQLITE_OK, SQLITE_DONE, nil) == .unconfirmedFailure)
    #expect(Decision.healthy != .confirmedCorrupt)
}

@Test func p304MissingRemovalClassifierDoesNotDiscardUnrelatedFailures() {
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    #expect(ThumbnailDiskCache.isMissingRemovalError(cocoa))
    #expect(ThumbnailDiskCache.isMissingRemovalError(posix))
    #expect(!ThumbnailDiskCache.isMissingRemovalError(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)))
    #expect(!ThumbnailDiskCache.isMissingRemovalError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    #expect(!ThumbnailDiskCache.isMissingRemovalError(NSError(domain: "other", code: Int(ENOENT))))
}

private func pngPaddedToExactLength(_ source: Data, targetLength: Int) throws -> Data {
    let input = [UInt8](source)
    let iend: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68]
    guard input.count >= 12, Array(input.suffix(12).prefix(8)) == iend,
          targetLength >= input.count + 12 else {
        throw ImageDecodeError.invalidRequest
    }
    let paddingCount = targetLength - input.count - 12
    let type: [UInt8] = [110, 112, 65, 68] // npAD: ancillary, private PNG chunk.
    let body = type + [UInt8](repeating: 0, count: paddingCount)
    var crc: UInt32 = 0xffffffff
    for byte in body {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
    }
    crc ^= 0xffffffff
    let length = UInt32(paddingCount).bigEndian
    let checksum = crc.bigEndian
    var result = Data(input.dropLast(12))
    withUnsafeBytes(of: length) { result.append(contentsOf: $0) }
    result.append(contentsOf: body)
    withUnsafeBytes(of: checksum) { result.append(contentsOf: $0) }
    result.append(contentsOf: input.suffix(12))
    return result
}

@Test(.timeLimit(.minutes(2))) func p303DiskCacheReopensAndSeparatesSourceContent() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let image = try await pipeline.image(for: request)
    let firstStore = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await firstStore.prepare(request))
    try await firstStore.store(image, for: ticket)
    let reopened = ThumbnailDiskCache(directory: cacheDirectory)
    let secondTicket = try #require(try await reopened.prepare(request))
    let hit = try #require(try await reopened.load(secondTicket))
    #expect(try rgba(hit.image) == rgba(image.image))
    #expect(hit.sourcePixelSize == image.sourcePixelSize)

    try Data(contentsOf: fixture("orientation-2.tiff")).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    let replaced = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let replacementTicket = try #require(try await reopened.prepare(replaced))
    #expect(replacementTicket.key.filename != ticket.key.filename)
    #expect(try await reopened.load(replacementTicket).map { _ in true } == nil)
    #expect(try await reopened.load(ticket).map { _ in true } == nil)
}

@Test(.timeLimit(.minutes(2))) func p303DiskCacheHitIsMaterializedBeforeDraw() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let edge = 1024
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let cache = ThumbnailDiskCache(directory: cacheDirectory)

    func drawDuration(_ image: CGImage) -> Double {
        let target = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let start = ProcessInfo.processInfo.systemUptime
        target.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ProcessInfo.processInfo.systemUptime - start
    }

    var hitDurations: [Double] = []
    var lazyDurations: [Double] = []
    for sample in 0..<5 {
        let context = try #require(CGContext(data: nil, width: edge, height: edge,
            bitsPerComponent: 8, bytesPerRow: edge * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var state = UInt32(0x30304 + sample)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: edge * edge * 4, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state)
            pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[index + 3] = 255
        }
        let sourceImage = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        let file = folder.appendingPathComponent("noise-\(sample).png")
        try (png as Data).write(to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: edge, identityRoot: root)
        let decoded = try await pipeline.image(for: request)
        let ticket = try #require(try await cache.prepare(request))
        try await cache.store(decoded, for: ticket)
        let payload = try Data(contentsOf: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png"))
        let hit = try #require(try await ThumbnailDiskCache(directory: cacheDirectory).load(ticket))
        let lazySource = try #require(CGImageSourceCreateWithData(
            payload as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
        let lazy = try #require(CGImageSourceCreateImageAtIndex(lazySource, 0, nil))
        if sample.isMultiple(of: 2) {
            hitDurations.append(drawDuration(hit.image))
            lazyDurations.append(drawDuration(lazy))
        } else {
            lazyDurations.append(drawDuration(lazy))
            hitDurations.append(drawDuration(hit.image))
        }
    }
    let hitMinimum = try #require(hitDurations.min())
    let lazyMinimum = try #require(lazyDurations.min())
    #expect(hitMinimum * 3 < lazyMinimum)
}

@Test(.timeLimit(.minutes(2))) func p303ValidForeignPayloadAndBrokenIndexAreCacheMisses() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let original = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(original, for: ticket)
    let context = try #require(CGContext(data: nil, width: original.image.width, height: original.image.height,
        bitsPerComponent: 8, bytesPerRow: original.image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height))
    let other = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, other, nil)
    #expect(CGImageDestinationFinalize(destination))
    #expect(other.width == original.image.width && other.height == original.image.height)
    #expect(try rgba(other) != rgba(original.image))
    let storedPayload = try Data(contentsOf: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png"))
    bytes.setData(try pngPaddedToExactLength(bytes as Data, targetLength: storedPayload.count))
    let foreignSource = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    #expect(CGImageSourceGetStatusAtIndex(foreignSource, 0) == .statusComplete)
    let foreignPixels = try #require(CGImageSourceCreateImageAtIndex(foreignSource, 0, nil))
    #expect(foreignPixels.width == original.image.width && foreignPixels.height == original.image.height)
    #expect(try rgba(foreignPixels) != rgba(original.image))
    #expect((bytes as Data).count == storedPayload.count)
    try (bytes as Data).write(to: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png"))
    #expect(try await cache.load(ticket).map { _ in true } == nil)
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png").path))
    try Data("not sqlite".utf8).write(to: cacheDirectory.appendingPathComponent("index.sqlite3"))
    #expect(try await ThumbnailDiskCache(directory: cacheDirectory).load(ticket).map { _ in true } == nil)
}

@Test(.timeLimit(.minutes(2))) func p303StoredPayloadDropsSourceMetadata() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = try #require(CGContext(data: nil, width: 8, height: 8,
        bitsPerComponent: 8, bytesPerRow: 8 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let pixels = try #require(context.makeImage())
    let sourceBytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(sourceBytes, UTType.jpeg.identifier as CFString, 1, nil))
    let metadata: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:25 00:00:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.25, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "mado-test"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: "metadata-test"],
    ]
    CGImageDestinationAddImage(destination, pixels, metadata as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let file = folder.appendingPathComponent("metadata.jpg")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try (sourceBytes as Data).write(to: file)
    let metadataKeys: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
        kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
    let originalSource = try #require(CGImageSourceCreateWithData(sourceBytes as CFData, nil))
    let originalProperties = try #require(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any])
    for key in metadataKeys { #expect(originalProperties[key] != nil) }

    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 8, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let payload = try Data(contentsOf: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png"))
    let storedSource = try #require(CGImageSourceCreateWithData(payload as CFData, nil))
    let storedProperties = try #require(CGImageSourceCopyPropertiesAtIndex(storedSource, 0, nil) as? [CFString: Any])
    #expect(storedProperties[kCGImagePropertyGPSDictionary] == nil)
    #expect(storedProperties[kCGImagePropertyIPTCDictionary] == nil)
    let syntheticKeys: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension"]
    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary] {
        let dictionary = storedProperties[key] as? [CFString: Any]
        #expect(dictionary == nil || Set(dictionary!.keys.map { $0 as String }).isSubset(of: syntheticKeys))
    }
    var chunkTypes: [String] = []
    var offset = 8
    while offset + 12 <= payload.count {
        let length = payload[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        chunkTypes.append(String(decoding: payload[(offset + 4)..<(offset + 8)], as: UTF8.self))
        offset += 12 + Int(length)
    }
    #expect(offset == payload.count)
    #expect(Set(chunkTypes).isDisjoint(with: ["eXIf", "tEXt", "zTXt", "iTXt"]))
}

@Test(.timeLimit(.minutes(2))) func p303SourceEligibilityIsBoundedAndCancellationStopsHashing() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("large.bin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(ThumbnailDiskCache.maximumSourceBytes + 1))
    try handle.close()
    let revision = try FileRevisionReader.read(file)
    let render = RenderKey(itemID: .rootRelative(rootID: AccessRootID(), relativePath: file.lastPathComponent),
                           revision: revision, maximumPixelSize: 128)
    let request = ImageDecodeRequest(fileURL: file, maximumPixelSize: 128, renderKey: render)
    let cache = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"))
    #expect(try await cache.prepare(request).map { _ in true } == nil)
    let boundaryHandle = try FileHandle(forWritingTo: file)
    try boundaryHandle.truncate(atOffset: UInt64(ThumbnailDiskCache.maximumSourceBytes))
    try boundaryHandle.close()
    let boundaryRevision = try FileRevisionReader.read(file)
    let boundaryRender = RenderKey(itemID: render.itemID, revision: boundaryRevision, maximumPixelSize: 128)
    let boundaryRequest = ImageDecodeRequest(fileURL: file, maximumPixelSize: 128, renderKey: boundaryRender)
    #expect(try await cache.prepare(boundaryRequest).map { _ in true } == true)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await cache.prepare(request)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("cache").path))
}

@Test(.timeLimit(.minutes(2))) func p303MissingPayloadRebuildsAndChangedSourceCannotPublishOldTicket() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    let time = Date(timeIntervalSince1970: 1_000_000)
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let payload = cacheDirectory.appendingPathComponent(ticket.key.filename + ".png")
    try FileManager.default.removeItem(at: payload)
    #expect(try await cache.load(ticket).map { _ in true } == nil)
    try await cache.store(decoded, for: ticket)
    #expect(try await cache.load(ticket).map { _ in true } == true)

    try Data(contentsOf: fixture("orientation-2.tiff")).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    let oldPayload = try Data(contentsOf: payload)
    do {
        try await cache.store(decoded, for: ticket)
        Issue.record("changed source was accepted for store")
    } catch let error as ImageLoadError {
        #expect(error.kind == .sourceChanged)
    }
    #expect(try Data(contentsOf: payload) == oldPayload)
    #expect(try await cache.load(ticket).map { _ in true } == nil)
    let rejectedDirectory = folder.appendingPathComponent("rejected-cache")
    do {
        try await ThumbnailDiskCache(directory: rejectedDirectory).store(decoded, for: ticket)
        Issue.record("changed source was accepted for another store")
    } catch let error as ImageLoadError {
        #expect(error.kind == .sourceChanged)
    }
    #expect(!FileManager.default.fileExists(atPath: rejectedDirectory.path))
}

@Test(.timeLimit(.minutes(2))) func p303SourceChangedDuringPayloadPublicationLeavesNoIndexedImage() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    let time = Date(timeIntervalSince1970: 1_000_000)
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory, afterPayloadWrite: {
        try Data(contentsOf: fixture("orientation-2.tiff")).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    })
    let ticket = try #require(try await cache.prepare(request))
    do {
        try await cache.store(decoded, for: ticket)
        Issue.record("changed source was accepted after payload write")
    } catch let error as ImageLoadError {
        #expect(error.kind == .sourceChanged)
    }
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(ticket.key.filename + ".png").path))
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("index.sqlite3").path))
}

@Test(.timeLimit(.minutes(2))) func p303UnopenableIndexCannotDeliverPixels() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try FileManager.default.createDirectory(at: cacheDirectory.appendingPathComponent("index.sqlite3"),
        withIntermediateDirectories: true)
    await #expect(throws: Error.self) { try await cache.store(decoded, for: ticket) }
    #expect(try await cache.load(ticket).map { _ in true } == nil)
}

@Test(.timeLimit(.minutes(2))) func p303DamagedIndexDimensionsCannotAlterDeliveredSourceSize() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(cacheDirectory.appendingPathComponent("index.sqlite3").path,
                            &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { if let db { sqlite3_close(db) } }
    #expect(sqlite3_exec(db, "UPDATE thumbnails SET source_width=999", nil, nil, nil) == SQLITE_OK)
    #expect(try await cache.load(ticket).map { _ in true } == nil)
}

@Test(.timeLimit(.minutes(2))) func p304NextAccessRepairsOrphanAndDamagedRowWithoutChangingSource() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let sourceBytes = try Data(contentsOf: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let payload = cacheDirectory.appendingPathComponent(ticket.key.filename + ".png")
    let orphan = cacheDirectory.appendingPathComponent(String(repeating: "a", count: 64) + ".png")
    try Data(contentsOf: payload).write(to: orphan)
    try Data("bad PNG".utf8).write(to: payload)

    let reopened = ThumbnailDiskCache(directory: cacheDirectory)
    #expect(try await reopened.load(ticket).map { _ in true } == nil)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(!FileManager.default.fileExists(atPath: payload.path))
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(cacheDirectory.appendingPathComponent("index.sqlite3").path,
                            &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { if let db { sqlite3_close(db) } }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM thumbnails", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 0)
    #expect(try Data(contentsOf: file) == sourceBytes)
    #expect(try await reopened.load(ticket).map { _ in true } == nil)
}

@Test(.timeLimit(.minutes(2))) func p304RecentReadSurvivesHighLowWaterEviction() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<3 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    try await seed.store(images[1], for: tickets[1])
    let firstPayload = cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")
    let secondPayload = cacheDirectory.appendingPathComponent(tickets[1].key.filename + ".png")
    let bytes = try Data(contentsOf: firstPayload).count
    #expect(try Data(contentsOf: secondPayload).count == bytes)
    let limited = ThumbnailDiskCache(directory: cacheDirectory,
                                     highWaterBytes: 2 * bytes + 1, lowWaterBytes: 2 * bytes)
    #expect(try await limited.load(tickets[0]).map { _ in true } == true)
    try await limited.store(images[2], for: tickets[2])
    #expect(FileManager.default.fileExists(atPath: firstPayload.path))
    #expect(!FileManager.default.fileExists(atPath: secondPayload.path))
    #expect(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(tickets[2].key.filename + ".png").path))
    #expect(try await limited.load(tickets[0]).map { _ in true } == true)
    #expect(try await limited.load(tickets[1]).map { _ in true } == nil)
}

private actor P304ReadGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume()
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume() }
}

@Test(.timeLimit(.minutes(2))) func p304HeldReaderKeepsPayloadDuringOtherCacheEviction() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<3 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    try await seed.store(images[1], for: tickets[1])
    let heldPayload = cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")
    let bytes = try Data(contentsOf: heldPayload).count
    let gate = P304ReadGate()
    let reader = ThumbnailDiskCache(directory: cacheDirectory, afterReadLeaseAcquired: { await gate.pause() })
    let heldTicket = tickets[0]
    let pending = Task { try await reader.load(heldTicket).map { _ in true } }
    await gate.waitForEntry()
    let evictor = ThumbnailDiskCache(directory: cacheDirectory,
                                     highWaterBytes: 2 * bytes + 1, lowWaterBytes: 2 * bytes)
    try await evictor.store(images[2], for: tickets[2])
    #expect(FileManager.default.fileExists(atPath: heldPayload.path))
    await gate.release()
    #expect(try await pending.value == true)
}

@Test(.timeLimit(.minutes(2))) func p304CorruptIndexRebuildsFromUnchangedSource() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let sourceBytes = try Data(contentsOf: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let index = cacheDirectory.appendingPathComponent("index.sqlite3")
    try Data("broken database".utf8).write(to: index)
    let reopened = ThumbnailDiskCache(directory: cacheDirectory)
    #expect(try await reopened.load(ticket).map { _ in true } == nil)
    try await reopened.store(decoded, for: ticket)
    #expect(try await reopened.load(ticket).map { _ in true } == true)
    #expect(try Data(contentsOf: file) == sourceBytes)
}

@Test(.timeLimit(.minutes(2))) func p304CancelledReadReleasesPayloadForEviction() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<2 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    let heldPayload = cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")
    let gate = P304ReadGate()
    let reader = ThumbnailDiskCache(directory: cacheDirectory, afterReadLeaseAcquired: { await gate.pause() })
    let heldTicket = tickets[0]
    let pending = Task { try await reader.load(heldTicket).map { _ in true } }
    await gate.waitForEntry()
    pending.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await pending.value }
    let evictor = ThumbnailDiskCache(directory: cacheDirectory, highWaterBytes: 1, lowWaterBytes: 0)
    try await evictor.store(images[1], for: tickets[1])
    #expect(!FileManager.default.fileExists(atPath: heldPayload.path))
}

@Test(.timeLimit(.minutes(2))) func p304WarmPixelsSurviveIndexBecomingUnavailableAfterRowRead() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let sourceBytes = try Data(contentsOf: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let expected = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(expected, for: ticket)
    let index = cacheDirectory.appendingPathComponent("index.sqlite3")
    let moved = cacheDirectory.appendingPathComponent("index-moved.sqlite3")
    let reader = ThumbnailDiskCache(directory: cacheDirectory, afterReadLeaseAcquired: {
        try? FileManager.default.moveItem(at: index, to: moved)
        try? FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    })
    let delivered = try #require(try await reader.load(ticket))
    #expect(try rgba(delivered.image) == rgba(expected.image))
    #expect(try Data(contentsOf: file) == sourceBytes)
    #expect(FileManager.default.fileExists(atPath: moved.path))
    #expect((try? FileManager.default.attributesOfItem(atPath: index.path)[.type] as? FileAttributeType) == .typeDirectory)
}
