import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
@testable import MadoApplication
@testable import MadoInfrastructure

// Issue 807 (OPEN-05): a truncated JPEG must fail as a damaged image (page 25 with Retry and Next), never show the
// part ImageIO managed to decode. Truncated fixtures are derived from repository bytes at test time.

private func issue807TextAsset(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/TextRecognition/\(name)")
}

private func issue807Folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("issue807-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Deterministic noise, so the encoded scan is large enough to cut in the middle.
private func issue807Pixels(width: Int, height: Int, cmyk: Bool = false) throws -> CGImage {
    let components = 4
    var bytes = [UInt8](repeating: 0, count: width * height * components)
    var state: UInt32 = 0x807
    for index in bytes.indices {
        state = state &* 1_664_525 &+ 1_013_904_223
        bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        if !cmyk, index % 4 == 3 { bytes[index] = 255 }
    }
    let space = cmyk ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB()
    let info = cmyk ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = try #require(bytes.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * components, space: space, bitmapInfo: info)
    })
    return try #require(context.makeImage())
}

private func issue807EncodeJPEG(_ image: CGImage, progressive: Bool = false) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Byte offset of the first start-of-scan marker.
private func issue807FirstScan(_ data: Data) throws -> Int {
    let bytes = [UInt8](data)
    return try #require(bytes.indices.dropLast().first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA })
}

private struct Issue807Case {
    let name: String
    let bytes: Data
}

private func issue807TruncatedCases() throws -> [Issue807Case] {
    let photo = try Data(contentsOf: issue807TextAsset("mixed-tall-narrow.jpg"))
    let baseline = try issue807EncodeJPEG(try issue807Pixels(width: 640, height: 480))
    let progressive = try issue807EncodeJPEG(try issue807Pixels(width: 640, height: 480), progressive: true)
    #expect(progressive != baseline)
    return [
        // The device repro's shape: a real photo cut part-way through its scan (head -c).
        Issue807Case(name: "photo-half.jpg", bytes: photo.prefix(photo.count / 2)),
        Issue807Case(name: "baseline-60.jpg", bytes: baseline.prefix(baseline.count * 6 / 10)),
        Issue807Case(name: "progressive-60.jpg", bytes: progressive.prefix(progressive.count * 6 / 10)),
        Issue807Case(name: "after-scan-header.jpg", bytes: baseline.prefix(try issue807FirstScan(baseline) + 40)),
        // Only the final EOI marker is missing.
        Issue807Case(name: "no-eoi.jpg", bytes: baseline.dropLast(2)),
    ]
}

private func issue807Write(_ item: Issue807Case, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(item.name)
    try item.bytes.write(to: url)
    return url
}

private func issue807ExpectCorrupt(_ name: String, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("\(name): expected corruptImage, got an image")
    } catch {
        #expect((error as? ImageLoadError)?.kind == .corruptImage, "\(name): \(error)")
    }
}

@Test(.timeLimit(.minutes(2))) func issue807TruncatedJPEGFailsAsCorruptImageOnEveryTier() async throws {
    let folder = try issue807Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for item in try issue807TruncatedCases() {
        let url = try issue807Write(item, in: folder)
        let pipeline = ImageIOPipeline()
        // Viewer request (preview and detail share it), the direct decode, and the thumbnail coverage request.
        await issue807ExpectCorrupt("\(item.name) request") {
            _ = try await pipeline.request(for: url, maximumPixelSize: 512)
        }
        await issue807ExpectCorrupt("\(item.name) image") {
            _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: url, maximumPixelSize: 512))
        }
        await issue807ExpectCorrupt("\(item.name) preview") {
            _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: url, maximumPixelSize: 512, isPreview: true))
        }
        await issue807ExpectCorrupt("\(item.name) thumbnail") {
            _ = try await pipeline.request(for: url, covering: ThumbnailCoverage(width: 128, height: 128),
                                           identityRoot: nil)
        }
        do {
            _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: url, maximumPixelSize: 512))
        } catch let failure as ImageLoadError {
            #expect(failure.revision?.byteCount == item.bytes.count, "\(item.name): the failure carries the file revision")
        }
    }
}

@Test(.timeLimit(.minutes(2))) func issue807TruncatedPNGStillFailsAsCorruptImage() async throws {
    await issue807ExpectCorrupt("truncated.png") {
        _ = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: fixture("truncated.png"), maximumPixelSize: 512))
    }
}

@Test(.timeLimit(.minutes(3))) func issue807ValidUnusualJPEGsStillDecode() async throws {
    let folder = try issue807Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let baseline = try issue807EncodeJPEG(try issue807Pixels(width: 320, height: 240))
    let cmyk = try issue807EncodeJPEG(try issue807Pixels(width: 320, height: 240, cmyk: true))
    let generated: [(String, Data)] = [
        ("progressive.jpg", try issue807EncodeJPEG(try issue807Pixels(width: 320, height: 240), progressive: true)),
        ("cmyk.jpg", cmyk),
        // Bytes after EOI (appended previews, motion-photo payloads, padding) are not part of the image.
        ("trailer.jpg", baseline + Data(repeating: 0x5A, count: 4096)),
        ("zero-padding.jpg", baseline + Data(repeating: 0, count: 512)),
    ]
    var files = try generated.map { name, bytes in
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    files += ["mixed-orientation-6.jpg", "mixed-oversize.jpg", "mixed-tall-narrow.jpg"].map(issue807TextAsset)
    let cmykSource = try #require(CGImageSourceCreateWithData(cmyk as CFData, nil))
    let cmykProperties = try #require(CGImageSourceCopyPropertiesAtIndex(cmykSource, 0, nil) as? [CFString: Any])
    #expect(cmykProperties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelCMYK as String)
    let pipeline = ImageIOPipeline()
    for url in files {
        let request = try await pipeline.request(for: url, maximumPixelSize: 512)
        let decoded = try await pipeline.image(for: request)
        #expect(decoded.image.width > 0 && decoded.image.height > 0, "\(url.lastPathComponent)")
        let thumbnail = try await pipeline.request(for: url, covering: ThumbnailCoverage(width: 64, height: 64),
                                                   identityRoot: nil)
        #expect(thumbnail.renderKey != nil, "\(url.lastPathComponent)")
    }
    let rotated = try await pipeline.image(for: ImageDecodeRequest(fileURL: issue807TextAsset("mixed-orientation-6.jpg"),
                                                                    maximumPixelSize: 2000))
    #expect(rotated.sourcePixelSize == CGSize(width: 1000, height: 340), "EXIF orientation 6 still reports the upright size")
}

@Test(.timeLimit(.minutes(2))) func issue807TruncatedJPEGThumbnailIsNeverCached() async throws {
    let folder = try issue807Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let item = try #require(try issue807TruncatedCases().first)
    let file = try issue807Write(Issue807Case(name: "image.jpg", bytes: item.bytes), in: folder)
    let cacheDirectory = folder.appendingPathComponent("cache")
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
                                store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "i807")
    let root = try await access.grant(folder: folder)
    let pipeline = ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: cacheDirectory))
    var source: AccessImageSource?
    await issue807ExpectCorrupt("thumbnail through the disk cache") {
        let opened = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
        source = opened
        _ = try await opened.image(maximumPixelSize: 128)
    }
    await source?.close()
    let payloads = (FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: nil)?.allObjects ?? [])
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }
    #expect(payloads.isEmpty, "no thumbnail payload is stored for a truncated file: \(payloads)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue807ViewerShowsTheUnreadableStateForTruncatedJPEG() async throws {
    let folder = try issue807Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let item = try #require(try issue807TruncatedCases().first)
    let file = try issue807Write(Issue807Case(name: "truncated-photo.jpg", bytes: item.bytes), in: folder)
    let session = ViewerSession(), host = CacheHost(), access = CacheLeases(), pipeline = ImageIOPipeline()
    session.imageLoader.host = host
    session.openImage(file, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    // .failed(.corruptImage, name) is page 25 with 重试 and 下一张 (ViewerInputHintTests: state.retry, state.next).
    #expect(session.imageStatus == .failed(.corruptImage, "truncated-photo.jpg"))
    #expect(host.names.isEmpty, "no partial frame is installed")
    #expect(!host.failures.isEmpty)
    session.closeImage(); await access.waitUntilEmpty()
}
