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
@MainActor @Test func loadSessionDeliversPreparedIdentityOnMainActor() async throws {
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
