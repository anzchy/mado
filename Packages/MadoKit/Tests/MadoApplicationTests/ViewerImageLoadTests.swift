import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

actor LoadLeases: AccessLeasing {
    var acquired: [AccessLease] = []
    var released: [AccessLease] = []
    func acquire(_ request: AccessRequest) -> AccessLease {
        let url: URL
        switch request { case .fileGrant(let file), .root(_, let file): url = file }
        let lease = AccessLease(url: url, rootID: nil)
        acquired.append(lease)
        return lease
    }
    func release(_ lease: AccessLease) { released.append(lease) }
}
func loadImage(_ key: RenderKey, edge: Int = 512, source: Int = 4000) -> DecodedImage {
    let context = CGContext(data: nil, width: edge, height: 1, bitsPerComponent: 8, bytesPerRow: edge * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: source, height: 2000),
                        revision: key.revision, itemID: key.itemID)
}
actor LoadPipeline: ImagePipeline {
    var edges: [Int] = []
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 123, modificationDate: nil)
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: revision, maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage {
        edges.append(request.maximumPixelSize)
        return loadImage(request.renderKey!, edge: request.maximumPixelSize)
    }
}
@MainActor final class LoadHost: ViewerImageHost {
    var images: [DecodedImage] = []
    var names: [String] = []
    var openings = 0
    var failures = 0
    func beginImageOpening() { MainActor.assertIsolated(); openings += 1 }
    func installImage(_ image: DecodedImage, fileURL: URL) {
        MainActor.assertIsolated(); images.append(image); names.append(fileURL.lastPathComponent)
    }
    func imageLoadFailed(_ error: any Error) { MainActor.assertIsolated(); failures += 1 }
}
@MainActor @Test(.timeLimit(.minutes(2))) func loadSessionDeliversPreparedIdentityOnMainActor() async throws {
    let session = ViewerSession(), host = LoadHost(), pipeline = LoadPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let url = URL(fileURLWithPath: "/A.png")
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(host.names == ["A.png", "A.png"])
    #expect(host.openings == 1)
    #expect(session.imageLoader.phase == .settled)
    #expect(session.imageLoader.presented?.key.itemID == pipeline.item)
    #expect(session.imageLoader.presented?.name == "A.png")
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue687RecognitionUsesHeldSourceAtRequestedFullResolution() async throws {
    let session = ViewerSession(), host = LoadHost(), pipeline = LoadPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    #expect(try await session.imageLoader.recognitionImage(maximumPixelSize: 4000) == nil)
    let url = URL(fileURLWithPath: "/recognise.png")
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(host.images.last?.image.width == 512)
    let full = try await session.imageLoader.recognitionImage(maximumPixelSize: 4000)
    #expect(full?.width == 4000)
    #expect(await pipeline.edges.last == 4000)
    session.closeImage()
    #expect(try await session.imageLoader.recognitionImage(maximumPixelSize: 4000) == nil)
}

private actor RecognitionFailingPipeline: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 9, modificationDate: nil)
    var failAtOrAbove = Int.max
    var failuresLeft = 0
    var edges: [Int] = []
    func configure(failAtOrAbove: Int, failures: Int) {
        self.failAtOrAbove = failAtOrAbove; failuresLeft = failures
    }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: revision, maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        edges.append(request.maximumPixelSize)
        if request.maximumPixelSize >= failAtOrAbove, failuresLeft > 0 {
            failuresLeft -= 1
            throw ImageLoadError(.resourceLimit)
        }
        return loadImage(request.renderKey!, edge: request.maximumPixelSize, source: 1000)
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue687DetailLimitedRecognitionFallsBackWithoutClosingDisplaySource() async throws {
    let session = ViewerSession(), host = LoadHost(), pipeline = RecognitionFailingPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    await pipeline.configure(failAtOrAbove: 1000, failures: 2)
    let url = URL(fileURLWithPath: "/detail-limited.png")
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    session.requireImageResolution(1000)
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .detailLimited)
    #expect(host.images.last?.image.width == 512)
    #expect(try await session.imageLoader.recognitionImage(maximumPixelSize: 1000) == nil)
    #expect(await pipeline.edges.filter { $0 == 1000 }.count == 1)
    #expect(await access.acquired.count - access.released.count == 1)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue687RecognitionDecodeFailureKeepsDisplayLeaseAndAllowsLaterRefine() async throws {
    let session = ViewerSession(), host = LoadHost(), pipeline = RecognitionFailingPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let url = URL(fileURLWithPath: "/transient-ocr.png")
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    await pipeline.configure(failAtOrAbove: 1000, failures: 1)
    #expect(try await session.imageLoader.recognitionImage(maximumPixelSize: 1000) == nil)
    #expect(await access.acquired.count - access.released.count == 1)
    session.requireImageResolution(700)
    await session.imageLoader.loadTask?.value
    #expect(host.images.last?.image.width == 700)
    let full = try await session.imageLoader.recognitionImage(maximumPixelSize: 1000)
    #expect(full?.width == 1000)
    #expect(await access.acquired.count - access.released.count == 1)
}
