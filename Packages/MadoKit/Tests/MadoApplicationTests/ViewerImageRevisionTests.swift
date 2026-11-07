import Foundation
import Testing
import MadoCore
@testable import MadoApplication

actor LoadRevisionPipeline: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    let changes: Int
    var attempts = 0
    init(changes: Int) { self.changes = changes }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: FileRevision(byteCount: 100 + attempts, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        attempts += 1
        if attempts <= changes {
            throw ImageLoadError(.sourceChanged, itemID: item, revision: FileRevision(byteCount: 100 + attempts, modificationDate: nil))
        }
        return loadImage(request.renderKey!, source: 512)
    }
}
@MainActor @Test func loadRevisionRetryKeepsGenerationAndReopenMintsAnother() async {
    let session = ViewerSession(), host = LoadHost(), access = LoadLeases(), pipeline = LoadRevisionPipeline(changes: 1)
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/replace.png")
    let opener: ViewerImageLoader.Opener = { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    session.openImage(file, maximumPixelSize: 512, opener: opener)
    let generation = session.imageLoader.generation
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.generation == generation)
    #expect(session.imageLoader.phase == .settled)
    #expect(host.openings == 2)
    #expect(host.images.count == 2)
    #expect(host.images.first?.revision?.byteCount == 101)
    session.openImage(file, maximumPixelSize: 512, opener: opener)
    #expect(session.imageLoader.generation != generation)
    await session.imageLoader.loadTask?.value
    #expect(host.images.count == 4)
}
@MainActor @Test func loadRevisionSecondChangeFailsWithTypedContext() async {
    let session = ViewerSession(), host = LoadHost(), access = LoadLeases(), pipeline = LoadRevisionPipeline(changes: 2)
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/replace.png")
    session.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.attempts == 2)
    #expect(session.imageLoader.phase == .failed)
    #expect((session.imageLoader.failure as? ImageLoadError)?.kind == .sourceChanged)
    #expect((session.imageLoader.failure as? ImageLoadError)?.revision?.byteCount == 102)
    #expect(host.images.isEmpty)
    #expect(host.failures == 1)
}
