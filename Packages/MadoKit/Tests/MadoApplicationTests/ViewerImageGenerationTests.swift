import Foundation
import Testing
import MadoCore
@testable import MadoApplication

actor GenerationPipeline: ImagePipeline {
    let root = AccessRootID()
    private var pending: [String: (ImageDecodeRequest, CheckedContinuation<DecodedImage, Never>)] = [:]
    private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]
    var cancelled: Set<String> = []
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: .rootRelative(rootID: root, relativePath: fileURL.lastPathComponent),
                revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) async -> DecodedImage {
        if !request.isPreview { return loadImage(request.renderKey!, source: 512) }
        let name = request.fileURL.lastPathComponent
        let image = await withCheckedContinuation {
            pending[name] = (request, $0)
            arrivals.removeValue(forKey: name)?.resume()
        }
        if Task.isCancelled { cancelled.insert(name) }
        return image
    }
    func entered(_ name: String) async {
        if pending[name] != nil { return }
        await withCheckedContinuation { arrivals[name] = $0 }
    }
    func release(_ name: String) {
        let (request, continuation) = pending.removeValue(forKey: name)!
        continuation.resume(returning: loadImage(request.renderKey!, source: 512))
    }
}
@MainActor func generationOpen(_ name: String, session: ViewerSession, pipeline: GenerationPipeline, access: LoadLeases) -> Task<Void, Never>? {
    let file = URL(fileURLWithPath: "/" + name)
    session.openImage(file, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    return session.imageLoader.loadTask
}
@MainActor @Test(.timeLimit(.minutes(2))) func loadGenerationsCThenBThenALastBalancesLeases() async {
    let session = ViewerSession(), host = LoadHost(), pipeline = GenerationPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let a = generationOpen("A", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("A")
    let b = generationOpen("B", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("B")
    let c = generationOpen("C", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("C")
    await pipeline.release("C"); await c?.value
    #expect(host.names == ["C", "C"])
    #expect(session.imageLoader.presented?.name == "C")
    await pipeline.release("B"); await b?.value
    await pipeline.release("A"); await a?.value
    #expect(host.names == ["C", "C"])
    #expect(session.imageLoader.phase == .settled)
    #expect(session.imageLoader.presented?.name == "C")
    #expect(await pipeline.cancelled == ["A", "B"])
    let acquired = await access.acquired, released = await access.released
    for name in ["A", "B"] {
        let tokens = acquired.filter { $0.url.lastPathComponent == name }
        #expect(tokens.count == 2)
        for lease in tokens { #expect(released.filter { $0 == lease }.count == 1) }
    }
}
@MainActor @Test(.timeLimit(.minutes(2))) func loadGenerationsALandsBetweenBAndCAndCloseDropsPending() async {
    let session = ViewerSession(), host = LoadHost(), pipeline = GenerationPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let a = generationOpen("A", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("A")
    let b = generationOpen("B", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("B")
    await pipeline.release("A"); await a?.value
    #expect(host.names.isEmpty)
    let c = generationOpen("C", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("C")
    session.closeImage()
    await pipeline.release("C"); await c?.value
    await pipeline.release("B"); await b?.value
    #expect(host.names.isEmpty)
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.phase == .idle)
    #expect(await pipeline.cancelled == ["A", "B", "C"])
    let acquired = await access.acquired, released = await access.released
    #expect(acquired.count == 6)
    #expect(released.count == 6)
    for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
}
