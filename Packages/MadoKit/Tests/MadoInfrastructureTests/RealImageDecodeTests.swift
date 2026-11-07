import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoInfrastructure

func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/\(name)")
}
final class DecodeCounter: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        lock.withLock { calls += 1 }
        return try TinyDecoder().decode(request)
    }
}
@Test func oversizeHeaderNeverReachesPixelDecoder() async {
    let decoder = DecodeCounter()
    let pipeline = ImageIOPipeline(decoder: decoder)
    await #expect(performing: {
        try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("oversize-header.png"), maximumPixelSize: 512))
    }, throws: loadError(.resourceLimit))
    #expect(decoder.count == 0)
}
func rgba(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}
@Test func realFixturesHaveIdenticalUprightPixelsAndPreserveAlpha() async throws {
    let pipeline = ImageIOPipeline()
    var reference: [UInt8] = []
    for orientation in 1...8 {
        let decoded = try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("orientation-\(orientation).tiff"), maximumPixelSize: 128))
        #expect(decoded.sourcePixelSize == CGSize(width: 128, height: 96))
        #expect(decoded.image.width == 128 && decoded.image.height == 96)
        let pixels = try rgba(decoded.image)
        if orientation == 1 { reference = pixels }
        #expect(pixels == reference)
    }
    let alpha = try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("alpha-gradient.png"), maximumPixelSize: 256))
    let pixels = try rgba(alpha.image)
    #expect(pixels[3] == 0)
    #expect(pixels[255 * 4 + 3] == 255)
    #expect(pixels[255 * 4] > 0)
    await #expect(performing: {
        try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("corrupt.png"), maximumPixelSize: 512))
    }, throws: loadError(.corruptImage))
    do {
        let partial = try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("truncated.png"), maximumPixelSize: 512))
        #expect(partial.image.width <= 64 && partial.image.height <= 48)
    } catch { #expect((error as? ImageLoadError)?.kind == .corruptImage) }
}
@Test func selfEncodedJPEGAndHEICDecodeAtRequestedSize() async throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let image = try #require(context.makeImage())
    for type in [UTType.jpeg, .heic] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension!)
        defer { try? FileManager.default.removeItem(at: file) }
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 16))
        #expect(decoded.image.width == 16 && decoded.image.height == 8)
        #expect(decoded.formatIdentifier == type.identifier)
    }
}

@Test func embeddedJPEGPreviewDoesNotReplaceSmallViewportDetail() async throws {
    let context = try #require(CGContext(data: nil, width: 2000, height: 1500, bitsPerComponent: 8, bytesPerRow: 8000,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
    defer { try? FileManager.default.removeItem(at: file) }
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()),
        [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let pipeline = ImageIOPipeline()
    let preview = try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 512, isPreview: true))
    #expect(preview.image.width < 512)
    let detail = try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 512))
    #expect(detail.image.width == 512)
    #expect(detail.image.height == 384)
    let smaller = try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 320))
    #expect(smaller.image.width == 320)
}

@Test func previewWithoutEmbeddedThumbnailDecodesSourcePixels() async throws {
    let pipeline = ImageIOPipeline()
    let oriented = try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("orientation-6.tiff"),
        maximumPixelSize: 128, isPreview: true))
    #expect(oriented.image.width == 128 && oriented.image.height == 96)
    let alpha = try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("alpha-gradient.png"),
        maximumPixelSize: 256, isPreview: true))
    #expect(try rgba(alpha.image)[3] == 0)
}

@Test func tinyAndTruncatedPreviewsRemainBoundedOrFailCleanly() async throws {
    for name in ["alpha-gradient.png", "truncated.png"] {
        for maximum in [1, 8, 128, 512] {
            do {
                let result = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: fixture(name),
                    maximumPixelSize: maximum, isPreview: true))
                #expect(result.image.width > 0 && result.image.height > 0)
                #expect(max(result.image.width, result.image.height) <= maximum)
            } catch {
                #expect(name == "truncated.png")
                #expect((error as? ImageLoadError)?.kind == .corruptImage)
            }
        }
    }
}
