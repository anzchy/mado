import Foundation
import ImageIO
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private actor TransientPinLease: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease { AccessLease(url: URL(fileURLWithPath: "/tmp"), rootID: nil) }
    func release(_ lease: AccessLease) {}
}

/// Schedules the existing pin boundary; all image/cache/budget work stays in the real pipeline.
private actor TransientPinPipeline: ImagePipeline, ImagePresentationPinning {
    enum Event: Sendable {
        case before(RenderKey, DecodedImage)
        case after(Bool)
        case finished
    }
    let base: ImageIOPipeline
    nonisolated let events: AsyncStream<Event>
    private let signal: AsyncStream<Event>.Continuation
    private var before: CheckedContinuation<Void, Never>?
    private var after: CheckedContinuation<Void, Never>?
    init(base: ImageIOPipeline) {
        self.base = base
        (events, signal) = AsyncStream.makeStream()
    }
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await base.request(for: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await base.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage { try await base.image(for: request) }
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) async -> Bool {
        await withCheckedContinuation { before = $0; signal.yield(.before(key, image)) }
        let accepted = await base.pin(key, image: image)
        await withCheckedContinuation { after = $0; signal.yield(.after(accepted)) }
        return accepted
    }
    func unpin(_ key: RenderKey) async { await base.unpin(key) }
    func releaseBefore() { before?.resume(); before = nil }
    func releaseAfter() { after?.resume(); after = nil }
    func finish() { signal.yield(.finished) }
}

private func withPermit(_ image: DecodedImage, _ permit: AccessWorkPermit) -> DecodedImage {
    DecodedImage(image: image.image, sourcePixelSize: image.sourcePixelSize, formatIdentifier: image.formatIdentifier,
        revision: image.revision, itemID: image.itemID, accessPermit: permit)
}

@Suite(.timeLimit(.minutes(2))) struct InspectorTransientPinOwnershipTests {
    @Test func issue194Fix1PinResultReflectsAtomicCacheAcquisition() async throws {
        let base = ImageIOPipeline(), url = fixture("landscape-3x2.png")
        let oldAuthority = AccessWorkAuthority(), currentAuthority = AccessWorkAuthority()
        let oldPermit = oldAuthority.permit(counter: 0), currentPermit = currentAuthority.permit(counter: 0)
        let prepared = try await base.request(for: url, maximumPixelSize: 240)
        let key = try #require(prepared.renderKey)
        let image = try await base.image(for: ImageDecodeRequest(fileURL: url, maximumPixelSize: 240,
            renderKey: key, accessPermit: oldPermit))
        #expect(await base.pin(key, image: withPermit(image, currentPermit)))
        let budget = try #require(base.cache.budget), before = budget.usage
        #expect(await base.cache.pinCount(for: key) == 1)
        let entries = await base.cache.usage().entries
        oldAuthority.update(counter: 1, readable: false)
        #expect(await base.pin(key, image: image) == false)
        #expect(await base.cache.pinCount(for: key) == 1)
        #expect(await base.cache.usage().entries == entries)
        #expect(budget.usage == before)
        #expect(await base.cache.image(for: key)?.image === image.image)
        await base.unpin(key)
        #expect(await base.cache.pinCount(for: key) == 0)
        #expect(budget.usage.pinned == 0 && budget.usage.reserved == 0)
    }

    @Test func issue194Fix1RejectedInspectorPinPreservesReauthorizedHolder() async throws {
        let base = ImageIOPipeline(), wrapper = TransientPinPipeline(base: base)
        let oldAuthority = AccessWorkAuthority(), currentAuthority = AccessWorkAuthority()
        let oldPermit = oldAuthority.permit(counter: 0), currentPermit = currentAuthority.permit(counter: 0)
        let url = fixture("landscape-3x2.png")
        let read = Task { () -> Result<InspectorMetadata, Error> in
            let result: Result<InspectorMetadata, Error>
            do { result = .success(try await ImageIOInspectorMetadataReader(access: TransientPinLease(), pipeline: wrapper,
                accessPermit: oldPermit).read(url, access: .fileGrant(url))) }
            catch { result = .failure(error) }
            await wrapper.finish()
            return result
        }
        var events = wrapper.events.makeAsyncIterator()
        guard case .before(let key, let image) = await events.next() else {
            Issue.record("Inspector never attempted transient acquisition"); _ = await read.value; return
        }
        // ImageIO and pipeline delivery finished with A. B now owns the same live key before A's pin executes.
        #expect(await base.pin(key, image: withPermit(image, currentPermit)))
        let budget = try #require(base.cache.budget), before = budget.usage
        let entries = await base.cache.usage().entries
        #expect(await base.cache.pinCount(for: key) == 1)
        #expect(before.reserved == 0 && before.pinned == image.image.bytesPerRow * image.image.height)
        oldAuthority.update(counter: 1, readable: false)
        await wrapper.releaseBefore()
        if case .after(let accepted) = await events.next() { #expect(!accepted) }
        else { Issue.record("Inspector acquisition did not forward to the real cache") }
        await wrapper.releaseAfter()
        switch await read.value {
        case .success: Issue.record("Revoked Inspector unexpectedly returned metadata")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(await base.cache.pinCount(for: key) == 1)
        #expect(await base.cache.usage().entries == entries)
        #expect(await base.cache.image(for: key)?.image === image.image)
        #expect(budget.usage == before)
        #expect(await base.admission.activity().running == 0)
        #expect(await base.admission.activity().waiting == 0)
        await base.unpin(key)
        #expect(budget.usage.pinned == 0 && budget.usage.reserved == 0)
    }

    @Test(arguments: [0, 1]) func issue194Fix1AcceptedInspectorPinAcquiresThenBalances(startingHolders: Int) async throws {
        let base = ImageIOPipeline(), wrapper = TransientPinPipeline(base: base)
        let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
        let url = fixture("landscape-3x2.png")
        let read = Task { () -> Result<InspectorMetadata, Error> in
            let result: Result<InspectorMetadata, Error>
            do { result = .success(try await ImageIOInspectorMetadataReader(access: TransientPinLease(), pipeline: wrapper,
                accessPermit: permit).read(url, access: .fileGrant(url))) }
            catch { result = .failure(error) }
            await wrapper.finish()
            return result
        }
        var events = wrapper.events.makeAsyncIterator()
        guard case .before(let key, let image) = await events.next() else {
            Issue.record("Inspector skipped transient acquisition"); _ = await read.value; return
        }
        if startingHolders == 1 { #expect(await base.pin(key, image: image)) }
        let budget = try #require(base.cache.budget)
        await wrapper.releaseBefore()
        if case .after(let accepted) = await events.next() { #expect(accepted) }
        else { Issue.record("Inspector acquisition did not finish") }
        // Reader cannot clean up yet: real acquisition completed but its result has not been delivered.
        #expect(await base.cache.pinCount(for: key) == startingHolders + 1)
        #expect(budget.usage.pinned == image.image.bytesPerRow * image.image.height)
        #expect(budget.usage.reserved == 0)
        await wrapper.releaseAfter()
        let metadata = try await read.value.get()
        let data = try #require(metadata.thumbnailData)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(thumbnail.width == 240 && thumbnail.height == 160)
        #expect(metadata.pixelWidth == 600 && metadata.pixelHeight == 400)
        #expect(await base.cache.pinCount(for: key) == startingHolders)
        #expect(budget.usage.reserved == 0)
        if startingHolders == 1 { await base.unpin(key) }
        #expect(budget.usage.pinned == 0)
    }
}
