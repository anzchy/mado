import Foundation
import Testing
import MadoCore
@testable import MadoApplication

enum ViewerPinEvent: Equatable, Sendable { case pin(RenderKey), unpin(RenderKey) }
actor ViewerPinRecorder: ImagePresentationPinning {
    private(set) var events: [ViewerPinEvent] = []
    private(set) var outstanding: [RenderKey: Int] = [:]
    private var drained: [CheckedContinuation<Void, Never>] = []
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) -> Bool {
        events.append(.pin(key)); outstanding[key, default: 0] += 1
        return true
    }
    func unpin(_ key: RenderKey) {
        events.append(.unpin(key))
        if let count = outstanding[key] {
            if count == 1 { outstanding.removeValue(forKey: key) } else { outstanding[key] = count - 1 }
        }
        if outstanding.isEmpty { let waiting = drained; drained.removeAll(); for waiter in waiting { waiter.resume() } }
    }
    func waitUntilEmpty() async {
        if !outstanding.isEmpty { await withCheckedContinuation { drained.append($0) } }
    }
}

private actor PinFailurePipeline: ImagePipeline {
    let mode: Int
    let item = ItemID.ephemeral(UUID())
    private var revision = 1
    init(mode: Int) { self.mode = mode }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: FileRevision(byteCount: revision, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        if !request.isPreview {
            if mode == 0 { throw ImageLoadError(.corruptImage) }
            if mode == 1 || mode == 2 { throw ImageLoadError(.resourceLimit) }
            if revision == 1 { revision = 2; throw ImageLoadError(.sourceChanged) }
        }
        return loadImage(request.renderKey!, edge: request.maximumPixelSize)
    }
}

@MainActor private final class PinOpenCount { var value = 0 }

private actor SuspendedPinPort: ImagePresentationPinning {
    let notifications: AsyncStream<Bool>
    private let signal: AsyncStream<Bool>.Continuation
    private(set) var outstanding: [RenderKey: Int] = [:]
    private var first = true
    private var suspended: CheckedContinuation<Void, Never>?
    private var drained: [CheckedContinuation<Void, Never>] = []
    init() { (notifications, signal) = AsyncStream.makeStream() }
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) async -> Bool {
        outstanding[key, default: 0] += 1
        if first {
            first = false
            await withCheckedContinuation { suspended = $0; signal.yield(true) }
        }
        return true
    }
    func unpin(_ key: RenderKey) {
        if let count = outstanding[key] {
            if count == 1 { outstanding.removeValue(forKey: key) } else { outstanding[key] = count - 1 }
        }
        if outstanding.isEmpty { let waiting = drained; drained.removeAll(); for waiter in waiting { waiter.resume() } }
    }
    func release() { suspended?.resume(); suspended = nil }
    func loadFinished() { signal.yield(false) }
    func waitUntilEmpty() async {
        if !outstanding.isEmpty { await withCheckedContinuation { drained.append($0) } }
    }
}

@MainActor private final class PinClosingHost: ViewerImageHost {
    let session: ViewerSession
    var installs = 0
    init(_ session: ViewerSession) { self.session = session }
    func beginImageOpening() { }
    func installImage(_ image: DecodedImage, fileURL: URL) { installs += 1; if installs == 2 { session.closeImage() } }
    func imageLoadFailed(_ error: any Error) { }
}

@Suite @MainActor struct ViewerImagePinTests {
    @Test(.timeLimit(.minutes(2))) func loaderPinsAcceptedTiersAndBalancesAtoBtoClose() async {
        let port = ViewerPinRecorder(), pipeline = LoadPipeline(), access = LoadLeases(), host = LoadHost()
        let loader = ViewerImageLoader(trace: nil, presentation: port)
        let session = ViewerSession(imageLoader: loader)
        loader.host = host
        for name in ["A.png", "B.png"] {
            let file = URL(fileURLWithPath: "/" + name)
            session.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
            await loader.loadTask?.value
            #expect(loader.phase == .settled)
            #expect(loader.presented?.name == name)
        }
        let detail = loader.presented!.key
        let preview = RenderKey(itemID: detail.itemID, revision: detail.revision, maximumPixelSize: 512, isPreview: true)
        #expect(await port.outstanding == [detail: 1])
        #expect(host.names == ["A.png", "A.png", "B.png", "B.png"])
        #expect(host.images.allSatisfy { $0.itemID == detail.itemID && $0.revision == detail.revision })
        session.closeImage(); await port.waitUntilEmpty()
        #expect(loader.phase == .idle && loader.presented == nil)
        #expect(await port.events == [.pin(preview), .pin(detail), .unpin(preview), .unpin(detail),
                                     .pin(preview), .pin(detail), .unpin(preview), .unpin(detail)])
    }

    @Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2, 3]) func loaderFailureRetryAndLimitedPreviewPins(mode: Int) async {
        let port = ViewerPinRecorder(), pipeline = PinFailurePipeline(mode: mode), access = LoadLeases(), host = LoadHost()
        let loader = ViewerImageLoader(trace: nil, presentation: port), opens = PinOpenCount()
        let session = ViewerSession(imageLoader: loader), file = URL(fileURLWithPath: "/pin-failure.png")
        loader.host = host
        session.openImage(file, maximumPixelSize: 1000) {
            opens.value += 1
            if mode == 2 && opens.value == 2 { throw FileAccessError.startFailed }
            return try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
        }
        let generation = loader.generation
        await loader.loadTask?.value
        #expect(loader.generation == generation)
        #expect(loader.phase == (mode == 1 ? .detailLimited : mode == 3 ? .settled : .failed))
        #expect(host.images.count == (mode == 3 ? 3 : 1))
        #expect(host.images.first?.image.width == 512)
        #expect(host.failures == (mode == 0 || mode == 2 ? 1 : 0))
        if let key = loader.presented?.key {
            #expect(await port.outstanding == [key: 1])
            #expect(key.isPreview == (mode == 1))
        } else {
            await port.waitUntilEmpty()
            #expect(await port.outstanding.isEmpty)
        }
        if mode == 3 {
            let pins = await port.events.compactMap { event -> RenderKey? in if case .pin(let key) = event { return key }; return nil }
            #expect(pins.count == 3)
            #expect(pins.map { $0.revision.byteCount } == [1, 2, 2])
        }
        session.closeImage(); await port.waitUntilEmpty()
        #expect(loader.phase == .idle && loader.presented == nil)
        #expect(await port.outstanding.isEmpty)
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true]) func loaderSuspendedPinCannotLeakOrInstallOldGeneration(supersede: Bool) async {
        let port = SuspendedPinPort(), pipeline = LoadPipeline(), access = LoadLeases(), host = LoadHost()
        let loader = ViewerImageLoader(trace: nil, presentation: port), session = ViewerSession(imageLoader: loader)
        loader.host = host
        let a = URL(fileURLWithPath: "/A.png"), c = URL(fileURLWithPath: "/C.png")
        var signals = port.notifications.makeAsyncIterator()
        session.openImage(a, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(a), access: access, pipeline: pipeline) }
        let original = loader.loadTask
        let completion = Task { await original?.value; await port.loadFinished() }
        guard await signals.next() == true else {
            Issue.record("Presentation pin was never entered")
            session.closeImage(); await port.release(); await original?.value; await completion.value
            return
        }
        if supersede {
            session.openImage(c, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(c), access: access, pipeline: pipeline) }
            await loader.loadTask?.value
        } else { session.closeImage() }
        await port.release(); await original?.value; await completion.value
        #expect(host.names == (supersede ? ["C.png", "C.png"] : []))
        #expect(loader.phase == (supersede ? .settled : .idle))
        if let key = loader.presented?.key { #expect(await port.outstanding == [key: 1]) }
        else { #expect(await port.outstanding.isEmpty) }
        session.closeImage(); await port.waitUntilEmpty()
        #expect(await port.outstanding.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func loaderHostCloseDuringDetailInstallReleasesBothPins() async {
        let port = ViewerPinRecorder(), pipeline = LoadPipeline(), access = LoadLeases()
        let loader = ViewerImageLoader(trace: nil, presentation: port), session = ViewerSession(imageLoader: loader)
        let host = PinClosingHost(session), file = URL(fileURLWithPath: "/close.png")
        loader.host = host
        session.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
        await loader.loadTask?.value; await port.waitUntilEmpty()
        #expect(host.installs == 2)
        #expect(loader.phase == .idle && loader.presented == nil)
        #expect(await port.outstanding.isEmpty)
        #expect(await port.events.count == 4)
    }
}
