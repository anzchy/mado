import Foundation
import CoreGraphics
import Testing
import MadoCore
import MadoApplication

enum AccessPipelineFailure: Error { case expected }

actor AccessProbe: AccessLeasing {
    var active: Set<UUID> = []
    var denied = false
    func deny() { denied = true }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        if denied { throw FileAccessError.startFailed }
        let file: URL
        switch request { case .fileGrant(let url), .root(_, let url): file = url }
        let lease = AccessLease(url: file, rootID: nil)
        active.insert(lease.token); return lease
    }
    func release(_ lease: AccessLease) { active.remove(lease.token) }
    func count() -> Int { active.count }
}

actor AccessPipelineProbe: ImagePipeline {
    let access: AccessProbe
    var requests = 0
    var sawActiveLease = false
    var blocked = false
    var failure = false
    var continuation: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    init(access: AccessProbe) { self.access = access }
    func configure(blocked: Bool = false, failure: Bool = false) { self.blocked = blocked; self.failure = failure }
    func waitUntilDecoding() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        requests += 1
        sawActiveLease = await access.count() >= 2
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        if blocked {
            await withCheckedContinuation { continuation = $0; entered?.resume(); entered = nil }
        }
        if failure { throw AccessPipelineFailure.expected }
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1))
    }
}

@Test(.timeLimit(.minutes(2))) func accessImageSourceHoldsOldLeaseUntilDecodeActuallyReturns() async throws {
    let access = AccessProbe(); let pipeline = AccessPipelineProbe(access: access)
    let file = URL(fileURLWithPath: "/tmp/a.jpg")
    let old = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    await pipeline.configure(blocked: true)
    let decode = Task { try await old.image(maximumPixelSize: 512, isPreview: true) }
    await pipeline.waitUntilDecoding()
    #expect(await pipeline.sawActiveLease)
    #expect(await access.count() == 2)
    let next = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    decode.cancel(); await old.close(); await old.close()
    #expect(await access.count() == 3)
    await pipeline.resume()
    await #expect(throws: CancellationError.self) { try await decode.value }
    #expect(await access.count() == 1)
    await next.close()
    #expect(await access.count() == 0)
}

@Test(.timeLimit(.minutes(2))) func accessImageSourceNeverAsksPipelineWithoutLeaseAndReleasesErrors() async throws {
    let access = AccessProbe(); let pipeline = AccessPipelineProbe(access: access)
    let file = URL(fileURLWithPath: "/tmp/a.jpg")
    let source = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    let (request, _) = try await source.image(maximumPixelSize: 99)
    #expect(request.maximumPixelSize == 99 && !request.isPreview)
    #expect(await pipeline.sawActiveLease)
    #expect(await access.count() == 1)
    await pipeline.configure(failure: true)
    await #expect(throws: AccessPipelineFailure.expected) { try await source.image(maximumPixelSize: 99) }
    #expect(await access.count() == 0)
    let deniedSource = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    await access.deny()
    let before = await pipeline.requests
    await #expect(throws: FileAccessError.startFailed) { try await deniedSource.image(maximumPixelSize: 99) }
    await #expect(throws: FileAccessError.startFailed) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    #expect(await pipeline.requests == before)
    #expect(await access.count() == 0)
}

@Test(.timeLimit(.minutes(2))) func accessCancelledOpenAndClosedSourceDoNotLeakOrStartPipeline() async throws {
    let access = AccessProbe(); let pipeline = AccessPipelineProbe(access: access)
    let file = URL(fileURLWithPath: "/tmp/a.jpg")
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await access.count() == 0)
    let source = try await AccessImageSource.open(.root(AccessRootID(), file: file), access: access, pipeline: pipeline)
    let (request, _) = try await source.image(maximumPixelSize: 12)
    #expect(request.fileURL == file)
    await source.close()
    let before = await pipeline.requests
    await #expect(throws: FileAccessError.startFailed) { try await source.image(maximumPixelSize: 12) }
    #expect(await pipeline.requests == before)
    #expect(await access.count() == 0)
}

@Test(.timeLimit(.minutes(2))) func accessImageSourceCoverageFallsBackWhenPipelineCannotReadHeaderFirst() async throws {
    let access = AccessProbe(); let pipeline = AccessPipelineProbe(access: access)
    let source = try await AccessImageSource.open(.fileGrant(URL(fileURLWithPath: "/tmp/a.jpg")), access: access, pipeline: pipeline)
    let (request, _) = try await source.image(covering: ThumbnailCoverage(width: 424, height: 296), priority: .prefetch)
    await source.close()
    #expect(request.maximumPixelSize == 848)
    #expect(request.priority == .prefetch)
    #expect(await access.count() == 0)
}
