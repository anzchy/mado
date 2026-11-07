import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor SmallTierPipeline: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    var edges: [Int] = []
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        edges.append(request.maximumPixelSize)
        // Bound a broken implementation's repeated request so RED finishes without a timeout.
        if !request.isPreview && edges.filter({ $0 == request.maximumPixelSize }).count > 1 {
            throw ImageLoadError(.corruptImage)
        }
        return loadImage(request.renderKey!, edge: 160)
    }
}
@MainActor @Test func loadTiersNeverRepeatDeliveredRequestWhenDecoderReturnsSmallerPixels() async {
    let pipeline = SmallTierPipeline(), session = ViewerSession(), access = LoadLeases(), host = LoadHost()
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/small-tier.png")
    session.openImage(file, maximumPixelSize: 1000) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000])
    #expect(session.imageLoader.phase == .settled)
    #expect(host.failures == 0)
    session.requireImageResolution(1000)
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000])
    session.requireImageResolution(1500)
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000, 1500])
    #expect(session.imageLoader.phase == .settled)
}
