import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor DetailRevisionPipeline: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    let failAgain: Bool
    var version = 1
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    init(failAgain: Bool) { self.failAgain = failAgain }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: FileRevision(byteCount: version, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        if !request.isPreview && (version == 1 || failAgain) {
            version += 1
            throw ImageLoadError(.sourceChanged, itemID: item, revision: FileRevision(byteCount: version, modificationDate: nil))
        }
        if request.isPreview && version == 2 {
            await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
        }
        return loadImage(request.renderKey!, edge: request.maximumPixelSize)
    }
    func enteredRetry() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
@MainActor @Test(arguments: [false, true]) func loadRevisionAfterPreviewReentersOpeningWithinSameGeneration(failAgain: Bool) async {
    let session = ViewerSession(), pipeline = DetailRevisionPipeline(failAgain: failAgain), access = LoadLeases(), host = LoadHost()
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/revision-tier.png")
    session.openImage(file, maximumPixelSize: 1000) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    let generation = session.imageLoader.generation
    await pipeline.enteredRetry()
    #expect(session.imageLoader.phase == .opening)
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.generation == generation)
    #expect(host.openings == 2 && host.images.count == 1)
    await pipeline.release(); await session.imageLoader.loadTask?.value
    if failAgain {
        #expect(session.imageLoader.phase == .failed)
        #expect((session.imageLoader.failure as? ImageLoadError)?.kind == .sourceChanged)
        #expect((session.imageLoader.failure as? ImageLoadError)?.revision?.byteCount == 3)
    } else {
        #expect(session.imageLoader.phase == .settled)
        #expect(session.imageLoader.presented?.key.revision.byteCount == 2)
    }
}
