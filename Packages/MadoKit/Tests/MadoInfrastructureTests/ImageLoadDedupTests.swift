import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication
import MadoInfrastructure

private actor DedupLeases: AccessLeasing {
    var leases: Set<AccessLease> = []
    func acquire(_ request: AccessRequest) -> AccessLease {
        let lease = AccessLease(url: URL(fileURLWithPath: "/same"), rootID: nil)
        leases.insert(lease); return lease
    }
    func release(_ lease: AccessLease) { leases.remove(lease) }
}
private final class DedupDecoder: ImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    var count: Int { lock.withLock { runs } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        lock.withLock { runs += 1 }
        return DecodedImage(image: try TinyDecoder().decode(request).image, sourcePixelSize: CGSize(width: 1, height: 1),
                            revision: request.renderKey?.revision, itemID: request.renderKey?.itemID)
    }
}
private actor DedupPipeline: ImagePipeline {
    let admission: DecodeAdmission
    let key = RenderKey(itemID: .ephemeral(UUID()), revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: 1, isPreview: true)
    var entered = 0, cancelled = 0
    private var entrants: (Int, CheckedContinuation<Void, Never>)?
    private var cancellations: (Int, CheckedContinuation<Void, Never>)?
    init(_ admission: DecodeAdmission) { self.admission = admission }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: 1, renderKey: key, isPreview: true)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        let subscription = await admission.subscribe(request, key: request.renderKey!, cost: 4, heavy: false, priority: .current)
        entered += 1
        if let (target, waiter) = entrants, entered >= target { entrants = nil; waiter.resume() }
        return try await withTaskCancellationHandler {
            let image = try await subscription.value()
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await subscription.cancel(); await self.didCancel() }
        }
    }
    func waitEntered(_ count: Int) async {
        if entered >= count { return }
        await withCheckedContinuation { entrants = (count, $0) }
    }
    private func didCancel() {
        cancelled += 1
        if let (target, waiter) = cancellations, cancelled >= target { cancellations = nil; waiter.resume() }
    }
    func waitCancelled(_ count: Int) async {
        if cancelled >= count { return }
        await withCheckedContinuation { cancellations = (count, $0) }
    }
}
@MainActor private final class DedupHost: ViewerImageHost {
    var names: [String] = []
    func beginImageOpening() { }
    func installImage(_ image: DecodedImage, fileURL: URL) { MainActor.assertIsolated(); names.append(fileURL.lastPathComponent) }
    func imageLoadFailed(_ error: any Error) { }
}
@MainActor @Test(.timeLimit(.minutes(2)), arguments: [0, 1, 2]) func loadDedupTwoSessionsKeepIndependentSubscriptions(cancelCount: Int) async {
    let executor = ControlledExecutor(), decoder = DedupDecoder()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(budget: 100), executor: executor, decoder: decoder)
    let pipeline = DedupPipeline(admission), access = DedupLeases()
    let a = ViewerSession(), b = ViewerSession(), ah = DedupHost(), bh = DedupHost()
    a.imageLoader.host = ah; b.imageLoader.host = bh
    let file = URL(fileURLWithPath: "/same")
    let opener: ViewerImageLoader.Opener = { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    a.openImage(file, maximumPixelSize: 1, opener: opener)
    b.openImage(file, maximumPixelSize: 1, opener: opener)
    let at = a.imageLoader.loadTask, bt = b.imageLoader.loadTask
    await pipeline.waitEntered(2)
    #expect(executor.count == 1)
    if cancelCount > 0 {
        a.closeImage()
        #expect(a.imageLoader.phase == .idle)
        if a.imageLoader.phase == .idle { await pipeline.waitCancelled(1) }
    }
    if cancelCount == 2 {
        b.closeImage()
        #expect(b.imageLoader.phase == .idle)
        if b.imageLoader.phase == .idle { await pipeline.waitCancelled(2) }
    }
    executor.runFirst()
    if cancelCount < 2 {
        await pipeline.waitEntered(cancelCount == 0 ? 4 : 3)
        #expect(executor.count == 1)
        executor.runFirst()
    }
    await at?.value; await bt?.value
    switch cancelCount {
    case 0: #expect(ah.names == ["same", "same"]); #expect(bh.names == ["same", "same"]); #expect(decoder.count == 2)
    case 1: #expect(ah.names.isEmpty); #expect(bh.names == ["same", "same"]); #expect(decoder.count == 2)
    default: #expect(ah.names.isEmpty); #expect(bh.names.isEmpty); #expect(decoder.count == 0)
    }
    #expect(await admission.activity().reservedBytes == 0)
}
