import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
@testable import MadoApplication

// #874 fix round 1 WI-5 (audit i874-r1 opus M4): a file already in a format the service accepts, within its limits
// and upright, is sent as it is; anything else keeps the re-encoded PNG. The limit is the service's own: 32 MiB of
// base64, so at most 25,165,824 bytes of file, and 8192 px a side. A 24 MP JPEG is no longer refused only because its
// PNG re-encode is larger.

/// A real JPEG header (ImageIO reads its size) padded after the image to exactly `byteCount` bytes.
private func paddedJPEG874(byteCount: Int) -> Data {
    var data = makeJPEG869(8, 6)
    data.append(Data(repeating: 0, count: byteCount - data.count))
    return data
}

private func flatJPEG874(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil))
    let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    #expect(CGImageDestinationFinalize(destination))
    return buffer as Data
}

@Test func issue874Fix1TheOriginalByteLimitIsTheServiceBase64Cap() {
    // 25,165,824 bytes encode to exactly 32 MiB of base64; one byte more does not fit.
    #expect(TableRecognitionSource.maximumOriginalBytes == 25_165_824)
    #expect((TableRecognitionSource.maximumOriginalBytes + 2) / 3 * 4 == TableRecognitionGuards.maxEncodedImageBytes)
    #expect(TableRecognitionSource.sendsAsIs(paddedJPEG874(byteCount: 25_165_824)))
    #expect(!TableRecognitionSource.sendsAsIs(paddedJPEG874(byteCount: 25_165_825)), "too large stays refused")
    #expect(TableRecognitionGuards.image(paddedJPEG874(byteCount: 25_165_825)) == .failure(.imageTooLarge))
}

@Test func issue874Fix1A24MegapixelJPEGGoesAsItIs() throws {
    let jpeg = try flatJPEG874(width: 6000, height: 4000)
    #expect(TableRecognitionSource.sendsAsIs(jpeg))
    #expect(TableRecognitionGuards.image(jpeg) == .success("image/jpeg"))
}

@Test func issue874Fix1OnlyAcceptedUprightFilesWithinTheLimitsGoAsTheyAre() throws {
    #expect(TableRecognitionSource.sendsAsIs(makePNG869(4, 3)))
    #expect(TableRecognitionSource.sendsAsIs(makeGIF869(4, 3)))
    #expect(TableRecognitionSource.sendsAsIs(try flatJPEG874(width: 4, height: 3, orientation: 1)))
    // Rotated by its EXIF tag: the service may not apply it, so the upright PNG goes instead.
    #expect(!TableRecognitionSource.sendsAsIs(try flatJPEG874(width: 4, height: 3, orientation: 6)))
    // Formats the service does not take, and a side over 8192 px.
    #expect(!TableRecognitionSource.sendsAsIs(makeTIFF869(4, 3)))
    #expect(!TableRecognitionSource.sendsAsIs(makeBMP869(4, 3)))
    #expect(!TableRecognitionSource.sendsAsIs(Data("not an image".utf8)))
    #expect(!TableRecognitionSource.sendsAsIs(makePNG869(8193, 1)))
}

// MARK: - The viewer hands over the opened file's bytes, under a lease of its own

private func temporaryFile874(_ data: Data, name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mado-874-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue874Fix1TheViewerGivesTheShownFilesOwnBytes() async throws {
    let jpeg = try flatJPEG874(width: 40, height: 30)
    let url = try temporaryFile874(jpeg, name: "table.jpg")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let session = ViewerSession(), host = LoadHost(), pipeline = LoadPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: 1_000_000) == nil, "nothing open")
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: 1_000_000) == jpeg)
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: jpeg.count) == jpeg)
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: jpeg.count - 1) == nil,
            "a file over the limit is not read")
    // Every lease the read took is given back; the display keeps its own.
    #expect(await access.acquired.count - access.released.count == 1)
    session.closeImage()
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: 1_000_000) == nil, "closed")
}

/// Names each file by a revision of its own, so the bytes of a file replaced on disk do not match the one shown.
private actor RevisingPipeline874: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    var byteCount = 1
    func revise() { byteCount += 1 }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: RenderKey(itemID: item,
            revision: FileRevision(byteCount: byteCount, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage { loadImage(request.renderKey!, edge: 8) }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue874Fix1BytesOfAFileChangedSinceItWasShownAreNotUsed() async throws {
    let url = try temporaryFile874(makePNG869(4, 3), name: "changed.png")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let session = ViewerSession(), pipeline = RevisingPipeline874(), access = LoadLeases()
    session.imageLoader.host = LoadHost()
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: 1_000_000) != nil)
    await pipeline.revise()
    #expect(await session.imageLoader.recognitionOriginal(maximumByteCount: 1_000_000) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue874Fix1AnImageSourceReadsItsFileUnderAFreshLeaseAndNotWhenClosed() async throws {
    let png = makePNG869(4, 3)
    let url = try temporaryFile874(png, name: "root.png")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let access = LoadLeases(), pipeline = LoadPipeline()
    let source = try await AccessImageSource.open(.root(AccessRootID(), file: url), access: access, pipeline: pipeline)
    let read = try #require(try await source.originalData(maximumByteCount: png.count))
    #expect(read.1 == png)
    #expect(read.0?.itemID == pipeline.item)
    #expect(await access.acquired.count == 2, "the display lease and one for the read")
    #expect(await access.released.count == 1)
    await source.close()
    await #expect(throws: FileAccessError.startFailed) { try await source.originalData(maximumByteCount: png.count) }
}
