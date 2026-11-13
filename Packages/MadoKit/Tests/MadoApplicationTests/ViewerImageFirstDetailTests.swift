import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private struct TierCall: Equatable, Sendable {
    let edge: Int
    let isPreview: Bool
}
private actor FirstDetailPipeline: ImagePipeline {
    let sourceEdge: Int
    let item = ItemID.ephemeral(UUID())
    var calls: [TierCall] = []
    init(sourceEdge: Int) { self.sourceEdge = sourceEdge }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        calls.append(TierCall(edge: request.maximumPixelSize, isPreview: request.isPreview))
        if calls.count > 2 { throw ImageLoadError(.corruptImage) }
        let pixels = loadImage(request.renderKey!, edge: min(sourceEdge, request.maximumPixelSize))
        return DecodedImage(image: pixels.image, sourcePixelSize: CGSize(width: sourceEdge, height: 1),
                            revision: pixels.revision, itemID: pixels.itemID)
    }
}
@MainActor @Test(.timeLimit(.minutes(2)), arguments: [4000, 256])
func loadFirstDetailIsRequiredEvenWhenPreviewCoversViewport(sourceEdge: Int) async {
    let session = ViewerSession(), host = LoadHost(), access = LoadLeases()
    let pipeline = FirstDetailPipeline(sourceEdge: sourceEdge)
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/first-detail.png")
    session.openImage(file, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    let expected: [TierCall] = sourceEdge == 4000
        ? [TierCall(edge: 512, isPreview: true), TierCall(edge: 512, isPreview: false)]
        : [TierCall(edge: 512, isPreview: true), TierCall(edge: 256, isPreview: false)]
    #expect(await pipeline.calls == expected)
    #expect(session.imageLoader.presented?.key.isPreview == false)
    #expect(session.imageLoader.phase == .settled)
    #expect(host.images.count == 2 && host.failures == 0)
    session.requireImageResolution(512)
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.calls == expected)
    #expect(session.imageLoader.phase == .settled)
}
