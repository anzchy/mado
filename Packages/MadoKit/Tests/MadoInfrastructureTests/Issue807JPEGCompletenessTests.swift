import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
@testable import MadoApplication
@testable import MadoInfrastructure

// Issue 807 fix1: the truncated-JPEG check stays cheap (tail fast path, per-revision memo), its boundary at the
// file's first bytes is pinned, and the marker branches have spliced fixtures. Every fixture is derived at test time.

private func f1Asset(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/TextRecognition/\(name)")
}

private func f1Folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("issue807f1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func f1JPEG(width: Int, height: Int, progressive: Bool = false, seed: UInt32 = 0x807) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var state = seed
    for index in bytes.indices {
        state = state &* 1_664_525 &+ 1_013_904_223
        bytes[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 24)
    }
    let context = try #require(bytes.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    })
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return [UInt8](data as Data)
}

/// Offsets of every `FF code` pair.
private func f1Markers(_ bytes: [UInt8], _ code: UInt8) -> [Int] {
    bytes.indices.dropLast().filter { bytes[$0] == 0xFF && bytes[$0 + 1] == code }
}

/// One APP1 segment whose payload is `payload`.
private func f1APP1(_ payload: [UInt8]) -> [UInt8] {
    let length = payload.count + 2
    return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
}

private func f1Write(_ bytes: [UInt8], _ name: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

private func f1Pipeline(_ url: URL) async throws {
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: url, maximumPixelSize: 256)
    let decoded = try await pipeline.image(for: request)
    #expect(decoded.image.width > 0, "\(url.lastPathComponent)")
    _ = try await pipeline.request(for: url, covering: ThumbnailCoverage(width: 64, height: 64), identityRoot: nil)
}

private func f1ExpectCorrupt(_ url: URL) async {
    do {
        _ = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: url, maximumPixelSize: 256))
        Issue.record("\(url.lastPathComponent): expected corruptImage, got an image")
    } catch {
        #expect((error as? ImageLoadError)?.kind == .corruptImage, "\(url.lastPathComponent): \(error)")
    }
}

// MARK: cost

@Test(.timeLimit(.minutes(2))) func issue807f1CompleteJPEGIsAcceptedFromItsTailOnly() throws {
    let folder = try f1Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try f1JPEG(width: 1600, height: 1200)
    let url = try f1Write(bytes, "large.jpg", in: folder)
    let padded = try f1Write(bytes + [UInt8](repeating: 0, count: 700), "padded.jpg", in: folder)
    for file in [url, padded] {
        let report = try JPEGCompleteness().check(file, revision: nil)
        #expect(report.path == .tail, "\(file.lastPathComponent)")
        // The segments before the first scan (one 64 KB window) and the last 4 KB, not the scan.
        #expect(report.bytesRead <= 64 * 1024 + JPEGCompleteness.tailBytes, "\(file.lastPathComponent): \(report)")
        #expect(report.bytesRead * 8 < bytes.count, "\(file.lastPathComponent): \(report.bytesRead) of \(bytes.count)")
    }
}

@Test(.timeLimit(.minutes(2))) func issue807f1RepeatedChecksOfAnUnchangedFileReadNothing() throws {
    let folder = try f1Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try f1JPEG(width: 640, height: 480)
    // A trailer after EOI needs the full walk the first time.
    let trailer = try f1Write(bytes + [UInt8](repeating: 0x5A, count: 4096), "trailer.jpg", in: folder)
    let truncated = try f1Write(Array(bytes.prefix(bytes.count / 2)), "truncated.jpg", in: folder)
    let check = JPEGCompleteness()
    let first = try check.check(trailer, revision: try FileRevisionReader.read(trailer))
    #expect(first.path == .walk && first.bytesRead >= bytes.count)
    let second = try check.check(trailer, revision: try FileRevisionReader.read(trailer))
    #expect(second == .init(path: .memo, bytesRead: 0))
    check.observe(truncated)
    for _ in 0..<2 {
        #expect(throws: ImageDecodeError.unreadableImage) {
            try check.check(truncated, revision: try FileRevisionReader.read(truncated))
        }
    }
    #expect(check.reports(for: truncated).map(\.path) == [.walk, .memo])
    // A changed file (the download finished) is a new revision and is checked again.
    try Data(bytes).write(to: truncated)
    #expect(try check.check(truncated, revision: try FileRevisionReader.read(truncated)).path == .tail)
}

@Test(.timeLimit(.minutes(2))) func issue807f1CacheHitThumbnailRequestDoesNotWalkTheFile() async throws {
    let folder = try f1Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try f1JPEG(width: 1600, height: 1200, seed: 0x8071)
    let file = try f1Write(bytes, "photo.jpg", in: folder)
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
                                store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "i807f1")
    let root = try await access.grant(folder: folder)
    let pipeline = ImageIOPipeline(thumbnailCache: ThumbnailDiskCache(directory: folder.appendingPathComponent("cache")))
    JPEGCompleteness.shared.observe(file)
    for _ in 0..<2 {
        let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
        _ = try await source.image(maximumPixelSize: 128)
        await source.close()
    }
    let reports = JPEGCompleteness.shared.reports(for: file)
    let reads = reports.filter { $0.path != .memo }
    #expect(reads.count == 1, "only the first header read touches the file: \(reports)")
    #expect(reads.first?.path == .tail)
    #expect((reads.first?.bytesRead ?? .max) * 8 < bytes.count, "\(reports)")
    #expect(reports.count >= 2 && reports.dropFirst().allSatisfy { $0 == .init(path: .memo, bytesRead: 0) }, "\(reports)")
}

// MARK: boundary at the first bytes

@Test(.timeLimit(.minutes(2))) func issue807f1JPEGWithLeadingBytesIsNeverShown() async throws {
    let folder = try f1Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let bytes = try f1JPEG(width: 320, height: 240)
    for (name, preamble) in [("junk", [UInt8](repeating: 0x41, count: 16)), ("zeros", [UInt8](repeating: 0, count: 512)),
                             ("ff", [UInt8](repeating: 0xFF, count: 2))] {
        for (suffix, body) in [("complete", bytes), ("truncated", Array(bytes.prefix(bytes.count * 6 / 10)))] {
            let url = try f1Write(preamble + body, "\(name)-\(suffix).jpg", in: folder)
            // ImageIO does not type a JPEG with leading bytes, so the file can never decode, complete or truncated.
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) == nil, "\(url.lastPathComponent)")
            // Should ImageIO ever accept the preamble, the header runs the walk on the typed JPEG, and it needs SOI at byte 0.
            #expect(throws: ImageDecodeError.unreadableImage, "\(url.lastPathComponent)") {
                try JPEGCompleteness().check(url, revision: nil)
            }
            await f1ExpectCorrupt(url)
        }
    }
}

// MARK: marker branches

@Test(.timeLimit(.minutes(3))) func issue807f1SplicedMarkerVariantsDecodeOrFailAsTheyShould() async throws {
    let folder = try f1Folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let baseline = try f1JPEG(width: 320, height: 240)
    let progressive = try f1JPEG(width: 320, height: 240, progressive: true)
    let tiny = try f1JPEG(width: 8, height: 8, seed: 0x80)
    let restart = [UInt8](try Data(contentsOf: f1Asset("mixed-orientation-6.jpg")))

    // Preconditions: the fixtures really carry the structures they stand for.
    #expect(!f1Markers(progressive, 0xC2).isEmpty && f1Markers(progressive, 0xDA).count >= 2, "progressive is SOF2, several SOS")
    let restartScan = try #require(f1Markers(restart, 0xDA).first)
    #expect(!f1Markers(restart, 0xDD).isEmpty, "DRI present")
    #expect((0xD0...0xD7).contains(where: { !f1Markers(Array(restart[restartScan...]), UInt8($0)).isEmpty }), "RSTn inside the scan")

    let eoi = baseline.count - 2
    let firstSegment = 2                                               // Right after SOI.
    let fill = Array(baseline[..<firstSegment]) + [0xFF, 0xFF, 0xFF] + Array(baseline[firstSegment..<eoi])
        + [0xFF, 0xFF] + Array(baseline[eoi...])
    let thumbnailPayload = Array("http://mado.test/thumb\0".utf8) + tiny + [0, 0, 0, 0]
    let embedded = Array(baseline[..<2]) + f1APP1(thumbnailPayload) + Array(baseline[2...])
    let thumbnailEnd = 2 + 4 + thumbnailPayload.count - 4           // Just after the nested EOI.
    let thumbnailLast = Array(baseline[..<2]) + f1APP1(Array("http://mado.test/thumb\0".utf8) + tiny) + Array(baseline[2...])
    let thumbnailLastEnd = 2 + 4 + "http://mado.test/thumb\0".utf8.count + tiny.count
    let mpf = baseline + progressive
    let lengthTooSmall = Array(baseline[..<2]) + [0xFF, 0xE1, 0x00, 0x01] + Array(baseline[2...])
    let secondSOI = Array(baseline[..<2]) + [0xFF, 0xD8] + Array(baseline[2...])
    let progressiveSecondScan = f1Markers(progressive, 0xDA)[1]

    let valid: [(String, [UInt8])] = [
        ("restart.jpg", restart),
        ("progressive.jpg", progressive),
        ("fill.jpg", fill),
        ("embedded-thumbnail.jpg", embedded),
        ("mpf-like.jpg", mpf),
        ("mpf-second-cut.jpg", Array(mpf.prefix(baseline.count + progressive.count / 2))),
    ]
    let refused: [(String, [UInt8])] = [
        ("restart-cut.jpg", Array(restart.prefix(restartScan + (restart.count - restartScan) / 2))),
        ("progressive-after-second-scan.jpg", Array(progressive.prefix(progressiveSecondScan + 40))),
        ("fill-cut.jpg", Array(fill.prefix(fill.count * 6 / 10))),
        ("cut-at-nested-thumbnail-eoi.jpg", Array(embedded.prefix(thumbnailEnd))),
        ("cut-at-app1-end-after-thumbnail.jpg", Array(thumbnailLast.prefix(thumbnailLastEnd))),
        ("embedded-thumbnail-scan-cut.jpg", Array(embedded.prefix(embedded.count * 6 / 10))),
        ("mpf-primary-cut.jpg", Array(mpf.prefix(baseline.count / 2))),
        ("cut-with-zero-padding.jpg", Array(baseline.prefix(baseline.count * 6 / 10)) + [UInt8](repeating: 0, count: 512)),
        ("segment-length-1.jpg", lengthTooSmall),
        ("segment-past-eof.jpg", Array(embedded.prefix(2 + 4 + 10))),
        ("cut-in-segment-length.jpg", Array(baseline.prefix(5))),
        ("second-soi.jpg", secondSOI),
    ]
    #expect(Array(embedded[thumbnailEnd - 2..<thumbnailEnd]) == [0xFF, 0xD9], "the cut ends on the thumbnail's EOI")
    #expect(Array(thumbnailLast[thumbnailLastEnd - 2..<thumbnailLastEnd]) == [0xFF, 0xD9])

    for (name, bytes) in valid {
        let url = try f1Write(bytes, name, in: folder)
        #expect(throws: Never.self, "\(name)") { try JPEGCompleteness().check(url, revision: nil) }
        try await f1Pipeline(url)
    }
    for (name, bytes) in refused {
        let url = try f1Write(bytes, name, in: folder)
        #expect(throws: ImageDecodeError.unreadableImage, "\(name)") { try JPEGCompleteness().check(url, revision: nil) }
        await f1ExpectCorrupt(url)
    }
}
