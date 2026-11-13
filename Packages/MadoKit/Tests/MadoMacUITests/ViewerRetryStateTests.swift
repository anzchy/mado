import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2]) @MainActor func statesRetryPreservesIntentMintsGenerationAndResetsFit(_ mode: Int) async throws {
    let scene = StatesScene(), pipeline = StatesPipeline(), leases = StatesLeases()
    defer { scene.session.closeImage(); scene.window.close() }
    let file = URL(fileURLWithPath: "/folder/A.png"), root = AccessRootID()
    let request: AccessRequest? = mode == 0 ? .root(root, file: file) : mode == 1 ? .fileGrant(file) : nil
    var intent = ViewerRetryIntent(fileURL: file, accessRequest: request)
    #expect(intent.fileURL == file)
    #expect(StatesRequest(intent.accessRequest) == (mode == 0 ? .root(root, file) : mode == 1 ? .file(file) : .unspecified))
    await scene.open(file, request: request, pipeline: pipeline, leases: leases)?.value
    #expect(scene.canvas.hasImage)
    scene.session.openImage(file, maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
    await scene.session.imageLoader.loadTask?.value
    scene.session.reportCanvasZoom(2)
    let oldGeneration = scene.session.imageLoader.generation
    var retried: Task<Void, Never>?
    var observedURL: URL?
    var observedRequest: StatesRequest?
    scene.state.onRetry = {
        intent.reopen { url, request in
            observedURL = url; observedRequest = StatesRequest(request)
            retried = scene.open(url, request: request, pipeline: pipeline, leases: leases)
        }
    }
    scene.state.refresh()
    let retry = try #require(scene.state.buttons.first)
    retry.performClick(nil)
    #expect(observedURL == file)
    #expect(observedRequest == (mode == 0 ? .root(root, file) : mode == 1 ? .file(file) : .unspecified))
    #expect(scene.session.imageLoader.generation != oldGeneration)
    #expect(scene.session.zoomMode == .fit)
    #expect(!scene.canvas.hasImage)
    await retried?.value
    #expect(scene.session.imageLoader.presented?.fileURL == file)
    #expect(scene.canvas.hasImage)
    let acquired = await leases.requests
    #expect(StatesRequest(acquired.last) == (mode == 0 ? .root(root, file) : .file(file)))

    let c = URL(fileURLWithPath: "/C.png")
    intent = ViewerRetryIntent(fileURL: c, accessRequest: .fileGrant(c))
    scene.session.openImage(c, maximumPixelSize: 512) { throw ImageLoadError(.unsupportedFormat) }
    await scene.session.imageLoader.loadTask?.value
    scene.state.refresh()
    let retryC = try #require(scene.state.buttons.first)
    retryC.performClick(nil)
    #expect(observedURL == c)
    #expect(observedRequest == .file(c))
    await retried?.value
    #expect(scene.session.imageLoader.presented?.fileURL == c)
}
