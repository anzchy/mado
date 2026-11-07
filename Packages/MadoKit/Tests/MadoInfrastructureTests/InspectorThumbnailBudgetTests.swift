import Foundation
import ImageIO
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private actor ThumbnailLease: AccessLeasing {
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        AccessLease(url: URL(fileURLWithPath: "/tmp"), rootID: nil)
    }
    func release(_ lease: AccessLease) {}
}

/// Holds the external synchronous ImageIO decode, without replacing admission or its ledger.
private final class InspectorDecodeGate: ImageDecoding, @unchecked Sendable {
    let condition = NSCondition()
    private var opened = false
    private var entered = false
    let failure: Bool
    init(failure: Bool = false) { self.failure = failure }
    var started: Bool { condition.withLock { entered } }
    func open() { condition.withLock { opened = true; condition.broadcast() } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        condition.lock()
        entered = true
        while !opened { condition.wait() }
        condition.unlock()
        if failure { throw ImageDecodeError.unreadableImage }
        return try ImageIODecoder().decode(request)
    }
}

/// On the shared cancellation-driven wait (#398): a condition that never holds fails the test here, naming it.
private func inspectorWait(
    _ comment: String, fileID: String = #fileID, line: Int = #line, _ condition: () async -> Bool
) async throws {
    try await waitUntil(comment, fileID: fileID, line: line) { await condition() }
}

private struct InspectorFailingDecoder: ImageDecoding {
    let error: any Error & Sendable
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage { throw error }
}

private actor RootThumbnailLease: AccessLeasing {
    let root = AccessRootID()
    let folder: URL
    init(folder: URL) { self.folder = folder }
    func acquire(_ request: AccessRequest) throws -> AccessLease { AccessLease(url: folder, rootID: root) }
    func release(_ lease: AccessLease) {}
}

@Suite(.timeLimit(.minutes(2))) struct InspectorThumbnailBudgetTests {
    @Test func issue194RootIdentityAndPermitRemainScopedThroughThumbnailRead() async throws {
        let url = fixture("landscape-3x2.png"), pipeline = ImageIOPipeline()
        let lease = RootThumbnailLease(folder: url.deletingLastPathComponent())
        let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
        let reader = ImageIOInspectorMetadataReader(access: lease, pipeline: pipeline, accessPermit: permit)
        let metadata = try await reader.read(url, access: .root(lease.root, file: url))
        #expect(metadata.pixelWidth == 600 && metadata.thumbnailData != nil)
        #expect(try #require(pipeline.cache.budget).usage.pinned == 0)
        authority.update(counter: 1, readable: false)
        await #expect(throws: CancellationError.self) { try await reader.read(url, access: .root(lease.root, file: url)) }
    }

    @Test(arguments: [0, 1, 2]) func issue194ThumbnailPermissionErrorsDoNotBecomeOptionalFailures(kind: Int) async throws {
        let error: any Error & Sendable
        if kind == 0 { error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
        else if kind == 1 { error = NSError(domain: NSPOSIXErrorDomain, code: 13) }
        else { error = FileAccessError.startFailed }
        let pipeline = ImageIOPipeline(decoder: InspectorFailingDecoder(error: error))
        let url = fixture("landscape-3x2.png")
        await #expect(throws: InspectorReadError.noPermission) {
            try await ImageIOInspectorMetadataReader(access: ThumbnailLease(), pipeline: pipeline).read(url, access: .fileGrant(url))
        }
        #expect(try #require(pipeline.cache.budget).usage.reserved == 0)
    }

    @Test func issue194InspectorUsesSharedPipelineAndPreservesUprightThumbnail() async throws {
        for name in ["landscape-3x2.png", "portrait-2x3.png", "orientation-6.tiff"] {
            let pipeline = ImageIOPipeline()
            let url = fixture(name)
            let metadata = try await ImageIOInspectorMetadataReader(access: ThumbnailLease(), pipeline: pipeline)
                .read(url, access: .fileGrant(url))
            let data = try #require(metadata.thumbnailData)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(max(image.width, image.height) == (name.hasSuffix("tiff") ? 128 : 240))
            if name.hasSuffix("tiff") { #expect(image.width == 128 && image.height == 96) }
            #expect(metadata.pixelWidth != nil && metadata.byteSize != nil)
            #expect(await pipeline.admission.diagnostics().finished == 1)
            #expect(try #require(pipeline.cache.budget).usage.reserved == 0)
        }
    }

    @Test(arguments: [false, true]) func issue194InspectorWaitsForSharedBudgetOrCancels(cancel: Bool) async throws {
        let limit = 300_000, filler = cacheKey(194)
        let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: limit, cacheCapacity: limit))
        let budget = try #require(pipeline.cache.budget)
        await pipeline.pin(filler, image: cacheImage(try cachePixels(rows: limit / 16), key: filler))
        let url = fixture("landscape-3x2.png")
        let task = Task { try await ImageIOInspectorMetadataReader(access: ThumbnailLease(), pipeline: pipeline)
            .read(url, access: .fileGrant(url)) }
        do { try await inspectorWait("read queued") { await pipeline.admission.activity().waiting == 1 } }
        catch { task.cancel(); throw error }
        #expect(budget.usage.reserved == 0)
        if cancel {
            task.cancel()
            do { _ = try await task.value; Issue.record("Expected cancellation") }
            catch { #expect(error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled) }
        }
        await pipeline.unpin(filler)
        if !cancel { #expect(try await task.value.thumbnailData != nil) }
        #expect(await pipeline.admission.activity().waiting == 0)
        #expect(budget.usage.reserved == 0)
        #expect(budget.usage.pinned == 0)
        #expect(budget.peak <= limit)
    }

    @Test(arguments: ["success", "failure", "cancel"])
    func issue194InspectorActiveDecodeKeepsStagingUntilWorkerFinishes(outcome: String) async throws {
        let gate = InspectorDecodeGate(failure: outcome == "failure")
        defer { gate.open() }
        let pipeline = ImageIOPipeline(decoder: gate)
        let budget = try #require(pipeline.cache.budget), url = fixture("landscape-3x2.png")
        let task = Task { try await ImageIOInspectorMetadataReader(access: ThumbnailLease(), pipeline: pipeline)
            .read(url, access: .fileGrant(url)) }
        do { try await inspectorWait("decode started") { gate.started } }
        catch { task.cancel(); gate.open(); _ = try? await task.value; throw error }
        #expect(budget.usage.reserved > 0)
        if outcome == "cancel" { task.cancel(); #expect(budget.usage.reserved > 0) }
        gate.open()
        do {
            let value = try await task.value
            #expect(outcome != "cancel")
            #expect(value.pixelWidth == 600 && value.pixelHeight == 400)
            #expect((value.thumbnailData != nil) == (outcome == "success"))
        } catch { #expect(outcome == "cancel") }
        #expect(budget.usage.reserved == 0)
        #expect(await pipeline.admission.activity().running == 0)
        #expect(await pipeline.admission.activity().waiting == 0)
    }

    @Test func issue194ThumbnailResourceFailureKeepsHeaderAndMetadataOnlyReaderDoesNotDecode() async throws {
        let url = fixture("landscape-3x2.png")
        let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: 64))
        let value = try await ImageIOInspectorMetadataReader(access: ThumbnailLease(), pipeline: pipeline)
            .read(url, access: .fileGrant(url))
        #expect(value.pixelWidth == 600 && value.pixelHeight == 400)
        #expect(value.typeIdentifier == "public.png" && value.byteSize != nil)
        #expect(value.thumbnailData == nil)
        #expect(try #require(pipeline.cache.budget).usage.reserved == 0)
        let metadataOnly = try await ImageIOInspectorMetadataReader(access: ThumbnailLease()).read(url, access: .fileGrant(url))
        #expect(metadataOnly.pixelWidth == 600 && metadataOnly.thumbnailData == nil)
    }
}
