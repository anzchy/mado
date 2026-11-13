import Foundation
import Testing
import MadoCore
@testable import MadoApplication

enum AcceptanceMismatch: Sendable, CaseIterable { case valid, item, revision, missingItem, missingRevision, missingKey }
private actor AcceptancePipeline: ImagePipeline {
    let mode: AcceptanceMismatch
    let key = RenderKey(itemID: .ephemeral(UUID()), revision: FileRevision(byteCount: 123, modificationDate: nil, resourceIdentifier: "revision"),
                        maximumPixelSize: 512, frameIndex: 3, policy: .unorientedSDR, decoderVersion: 7, purpose: .thumbnail)
    init(_ mode: AcceptanceMismatch) { self.mode = mode }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: mode == .missingKey ? nil : key)
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage {
        let base = loadImage(key, source: 512)
        return DecodedImage(image: base.image, sourcePixelSize: base.sourcePixelSize,
            revision: mode == .missingRevision ? nil : (mode == .revision ? FileRevision(byteCount: 124, modificationDate: nil) : key.revision),
            itemID: mode == .missingItem ? nil : (mode == .item ? .ephemeral(UUID()) : key.itemID))
    }
}
@MainActor @Test(.timeLimit(.minutes(2)), arguments: AcceptanceMismatch.allCases) func loadAcceptanceRejectsWrongOrMissingIdentityAndKeepsCompleteKey(mode: AcceptanceMismatch) async {
    let trace = PreviewRecorder(), session = ViewerSession(imageLoader: ViewerImageLoader(trace: trace))
    let host = LoadHost(), pipeline = AcceptancePipeline(mode), access = LoadLeases()
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/accept.png")
    session.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    if mode == .valid {
        #expect(host.names == ["accept.png", "accept.png"])
        let key = session.imageLoader.presented?.key
        #expect(key?.frameIndex == 3 && key?.policy == .unorientedSDR)
        #expect(key?.decoderVersion == 7 && key?.purpose == .thumbnail)
        #expect(key?.revision.resourceIdentifier == "revision")
        #expect(key?.isPreview == false)
        #expect(trace.ends.map(\.1) == [.success])
    } else {
        #expect(host.images.isEmpty)
        #expect(session.imageLoader.phase == .failed)
        #expect((session.imageLoader.failure as? ImageLoadError)?.kind == .sourceChanged)
        #expect(host.failures == 1)
        #expect(trace.ends.map(\.1) == [.failed])
    }
}
private actor LoadOpenGate {
    let source: AccessImageSource
    private var pending: CheckedContinuation<AccessImageSource, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    init(_ source: AccessImageSource) { self.source = source }
    func open() async -> AccessImageSource {
        await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { pending?.resume(returning: source); pending = nil }
}
@MainActor @Test(.timeLimit(.minutes(2)), arguments: [false, true]) func loadLateOpenerCannotInstallAfterNewOpenOrClose(close: Bool) async throws {
    let a = URL(fileURLWithPath: "/A"), b = URL(fileURLWithPath: "/B")
    let access = LoadLeases(), pipeline = LoadPipeline(), host = LoadHost(), session = ViewerSession()
    session.imageLoader.host = host
    let source = try await AccessImageSource.open(.fileGrant(a), access: access, pipeline: pipeline)
    let gate = LoadOpenGate(source)
    session.openImage(a, maximumPixelSize: 512) { await gate.open() }
    let old = session.imageLoader.loadTask
    await gate.entered()
    if close { session.closeImage() }
    else {
        session.openImage(b, maximumPixelSize: 512) {
            try await AccessImageSource.open(.fileGrant(b), access: LoadLeases(), pipeline: pipeline)
        }
        await session.imageLoader.loadTask?.value
    }
    await gate.release(); await old?.value
    if close { #expect(host.names.isEmpty); #expect(session.imageLoader.phase == .idle) }
    else { #expect(host.names == ["B", "B"]); #expect(session.imageLoader.presented?.name == "B") }
    #expect(await access.acquired.count == 1)
    #expect(await access.released.count == 1)
}
