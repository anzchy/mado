import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test @MainActor func statesCancelRetiresDecodeBalancesLeasesAndEscDoesNotCancel() async {
    let session = ViewerSession(), host = LoadHost(), pipeline = GenerationPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let old = generationOpen("A.png", session: session, pipeline: pipeline, access: access)
    await pipeline.entered("A.png")
    let generation = session.imageLoader.generation
    #expect(session.imageStatus == .loading("A.png"))
    #expect(!CommandRouter().route(.escape, from: .key, to: session))
    #expect(session.imageLoader.generation == generation)
    #expect(session.imageStatus == .loading("A.png"))
    #expect(await pipeline.cancelled.isEmpty)
    #expect(old?.isCancelled == false)
    session.cancelImageOpening()
    session.cancelImageOpening()
    #expect(session.imageLoader.phase == .idle)
    #expect(session.imageStatus == .empty)
    #expect(session.imageLoader.generation != generation)
    #expect(old?.isCancelled == true)
    await pipeline.release("A.png")
    await old?.value
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.failure == nil)
    #expect(session.imageStatus == .empty)
    #expect(host.names.isEmpty)
    #expect(host.failures == 0)
    #expect(await pipeline.cancelled == ["A.png"])
    let acquired = await access.acquired, released = await access.released
    #expect(acquired.count == 2)
    #expect(released.count == 2)
    for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
}

private actor CancelOpenerGate {
    let source: AccessImageSource
    private var pending: CheckedContinuation<AccessImageSource, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    init(_ source: AccessImageSource) { self.source = source }
    func open() async -> AccessImageSource {
        await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func release() { pending?.resume(returning: source); pending = nil }
}

@Test @MainActor func statesCancelClosesLateOpenerExactlyOnce() async throws {
    let session = ViewerSession(), host = LoadHost(), pipeline = LoadPipeline(), access = LoadLeases()
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/late.png")
    let source = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    let gate = CancelOpenerGate(source)
    session.openImage(file, maximumPixelSize: 512) { await gate.open() }
    let old = session.imageLoader.loadTask
    await gate.entered()
    session.cancelImageOpening()
    session.cancelImageOpening()
    #expect(session.imageStatus == .empty)
    await gate.release(); await old?.value
    #expect(session.imageLoader.phase == .idle)
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.failure == nil)
    #expect(host.names.isEmpty)
    #expect(host.failures == 0)
    let acquired = await access.acquired, released = await access.released
    #expect(acquired.count == 1)
    #expect(released == acquired)
}

@MainActor private final class CancelledFailureHost: ViewerImageHost {
    weak var session: ViewerSession?
    var alerts = 0
    var installs = 0
    func beginImageOpening() {}
    func installImage(_ image: DecodedImage, fileURL: URL) { installs += 1 }
    func imageLoadFailed(_ error: any Error) {
        if session?.dismissCancelledImageFailure(error) != true { alerts += 1 }
    }
}

@Test @MainActor func statesCancelExternalFailureReturnsIdleWithoutAlert() async {
    let session = ViewerSession(), host = CancelledFailureHost()
    host.session = session; session.imageLoader.host = host
    session.openImage(URL(fileURLWithPath: "/cancelled.png"), maximumPixelSize: 512) {
        throw ImageLoadError(.cancelled)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .idle)
    #expect(session.imageStatus == .empty)
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.failure == nil)
    #expect(host.alerts == 0)
    #expect(host.installs == 0)
    #expect(!session.dismissCancelledImageFailure(ImageLoadError(.corruptImage)))
    #expect(!session.dismissCancelledImageFailure(FileAccessError.startFailed))
}

@Test @MainActor func statesCancelSwiftCancellationReturnsIdleWithoutAlert() async {
    let session = ViewerSession(), host = CancelledFailureHost()
    host.session = session; session.imageLoader.host = host
    session.openImage(URL(fileURLWithPath: "/cancelled-task.png"), maximumPixelSize: 512) {
        throw CancellationError()
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .idle)
    #expect(session.imageStatus == .empty)
    #expect(session.imageLoader.failure == nil)
    #expect(host.alerts == 0)
}
