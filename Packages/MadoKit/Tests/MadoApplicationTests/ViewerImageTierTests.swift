import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor @Test(.timeLimit(.minutes(2))) func loadTiersPreviewViewportGrowThenSourceWithoutDowngrade() async {
    let session = ViewerSession(), host = LoadHost(), pipeline = LoadPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let url = URL(fileURLWithPath: "/tiers.png")
    session.openImage(url, maximumPixelSize: 1000) {
        try await AccessImageSource.open(.fileGrant(url), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000])
    session.requireImageResolution(1500)
    #expect(session.imageLoader.phase == .refining)
    #expect(host.images.last?.image.width == 1000)
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000, 1500])
    session.requireImageResolution(4000)
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000, 1500, 4000])
    session.requireImageResolution(1000)
    await session.imageLoader.loadTask?.value
    #expect(await pipeline.edges == [512, 1000, 1500, 4000])
    #expect(host.images.last?.image.width == 4000)
    #expect(session.imageLoader.phase == .settled)
}

private actor RefiningPipeline: ImagePipeline {
    let base = LoadPipeline()
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    var edges: [Int] = []
    func request(for fileURL: URL, maximumPixelSize: Int) async -> ImageDecodeRequest {
        await base.request(for: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func image(for request: ImageDecodeRequest) async -> DecodedImage {
        edges.append(request.maximumPixelSize)
        if !request.isPreview {
            await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
        }
        return loadImage(request.renderKey!, edge: request.maximumPixelSize)
    }
    func enteredDetail() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
@MainActor @Test(.timeLimit(.minutes(2))) func loadTiersRetainPreviewWhileHigherTierIsActuallyInFlight() async {
    let session = ViewerSession(), host = LoadHost(), pipeline = RefiningPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/refining.png")
    session.openImage(file, maximumPixelSize: 1000) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await pipeline.enteredDetail()
    #expect(await pipeline.edges == [512, 1000])
    #expect(session.imageLoader.phase == .refining)
    #expect(host.images.count == 1 && host.images.first?.image.width == 512)
    #expect(session.imageLoader.presented?.key.maximumPixelSize == 512)
    await pipeline.release(); await session.imageLoader.loadTask?.value
    #expect(host.images.count == 2 && host.images.last?.image.width == 1000)
    #expect(session.imageLoader.phase == .settled)
}
