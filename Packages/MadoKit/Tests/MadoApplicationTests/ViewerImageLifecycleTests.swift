import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor FailingDetailPipeline: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        if !request.isPreview { throw ImageLoadError(.corruptImage, itemID: item, revision: request.renderKey?.revision) }
        return loadImage(request.renderKey!)
    }
}
@MainActor @Test(.timeLimit(.minutes(2))) func loadLifecycleCloseIgnoresLateResolutionAndFailureClearsPresentedIdentity() async {
    let file = URL(fileURLWithPath: "/lifecycle.png"), access = LoadLeases(), host = LoadHost(), session = ViewerSession()
    session.imageLoader.host = host
    let pipeline = LoadPipeline()
    session.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    session.closeImage()
    session.requireImageResolution(4000)
    #expect(session.imageLoader.phase == .idle)
    let failing = FailingDetailPipeline()
    session.openImage(file, maximumPixelSize: 1000) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: failing) }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .failed)
    #expect(session.imageLoader.presented == nil)
    #expect(host.failures == 1)
}
@MainActor private final class ClosingImageHost: ViewerImageHost {
    let session: ViewerSession
    init(_ session: ViewerSession) { self.session = session }
    func beginImageOpening() { }
    func installImage(_ image: DecodedImage, fileURL: URL) { session.closeImage() }
    func imageLoadFailed(_ error: any Error) { }
}
@MainActor @Test(.timeLimit(.minutes(2))) func loadLifecycleHostCloseDuringInstallKeepsClosedState() async {
    let session = ViewerSession(), pipeline = LoadPipeline(), access = LoadLeases()
    let host = ClosingImageHost(session)
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/close.png")
    session.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .idle)
    #expect(session.imageLoader.presented == nil)
}
