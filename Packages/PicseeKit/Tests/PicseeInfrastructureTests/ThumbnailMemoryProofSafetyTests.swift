import CoreGraphics
import Foundation
import ImageIO
import PicseeApplication
import PicseeCore
import Testing
import UniformTypeIdentifiers
@testable import PicseeInfrastructure

private actor Issue452ValidationPause {
    private var armed = false
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm() { armed = true; entered = false }
    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() {
        armed = false
        continuation?.resume(); continuation = nil
    }
}

private func issue452SolidTIFF(_ file: URL, red: CGFloat) throws {
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
        bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    try #require(CGImageDestinationFinalize(destination))
}

private struct Issue452ProofFixture {
    let base: URL
    let files: [URL]
    let cacheDirectory: URL
    let scope: CountingScope
    let access: FileAccess
    let root: AccessRootID
    let disk: ThumbnailDiskCache
    let decoder: CacheCountingDecoder
    let pipeline: ImageIOPipeline

    static func make(pause: Issue452ValidationPause? = nil) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [folder.appendingPathComponent("red.tiff"), folder.appendingPathComponent("blue.tiff")]
        try issue452SolidTIFF(files[0], red: 1)
        try issue452SolidTIFF(files[1], red: 0)
        let scope = CountingScope()
        let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "i452-mem-proof")
        let root = try await access.grant(folder: folder)
        let cacheDirectory = base.appendingPathComponent("cache")
        let disk: ThumbnailDiskCache
        if let pause {
            disk = ThumbnailDiskCache(directory: cacheDirectory, afterReadLeaseAcquired: { await pause.pauseIfArmed() })
        } else { disk = ThumbnailDiskCache(directory: cacheDirectory) }
        let decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder,
            configuration: DecodeConfiguration(budget: 1_048_576, cacheCapacity: 1_048_576), thumbnailCache: disk)
        return Self(base: base, files: files, cacheDirectory: cacheDirectory, scope: scope,
            access: access, root: root, disk: disk, decoder: decoder, pipeline: pipeline)
    }

    func load(_ index: Int = 0, permit: AccessWorkPermit? = nil,
              pipeline other: ImageIOPipeline? = nil) async throws -> (ImageDecodeRequest, DecodedImage) {
        let source = try await AccessImageSource.open(.root(root, file: files[index]), access: access,
            pipeline: other ?? pipeline, accessPermit: permit)
        do {
            let value = try await source.image(maximumPixelSize: 64, priority: .visible)
            await source.close()
            return value
        } catch { await source.close(); throw error }
    }

    /// This precondition prevents a safety case from passing while the new native path was never exercised.
    func warm(permit: AccessWorkPermit? = nil) async throws -> (ImageDecodeRequest, DecodedImage, DiagnosticsSnapshot) {
        let (_, cold) = try await load(permit: permit)
        let (request, warm) = try await load(permit: permit)
        let snapshot = await pipeline.diagnostics()
        #expect(cold.image === warm.image)
        #expect(try rgba(warm.image) == rgba(ImageIODecoder().decode(ImageDecodeRequest(fileURL: files[0], maximumPixelSize: 64)).image))
        try #require(snapshot.memoryCache?.hits == 1)
        #expect(snapshot.memoryCache?.entries == 1)
        #expect(snapshot.diskCache?.hits == 0)
        #expect(decoder.count == 1)
        return (request, warm, snapshot)
    }
}

@Test func issue452NativeWarmProofRejectsSameRevisionContentChange() async throws {
    let f = try await Issue452ProofFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: f.files[0].path)
    let originalRevision = try FileRevisionReader.read(f.files[0])
    let attributes = try FileManager.default.attributesOfItem(atPath: f.files[0].path)
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
    let bytesA = try Data(contentsOf: f.files[0]), bytesB = try Data(contentsOf: f.files[1])
    try #require(bytesA.count == bytesB.count)
    let expectedB = try ImageIODecoder().decode(ImageDecodeRequest(fileURL: f.files[1], maximumPixelSize: 64))
    let (requestA, warmA, before) = try await f.warm()
    #expect(try rgba(warmA.image) != rgba(expectedB.image))
    let ticketA = try #require(try await f.disk.prepare(requestA))
    try bytesB.write(to: f.files[0])
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: f.files[0].path)
    let changedAttributes = try FileManager.default.attributesOfItem(atPath: f.files[0].path)
    #expect(changedAttributes[.systemFileNumber] as? NSNumber == inode)
    #expect(changedAttributes[.size] as? NSNumber == attributes[.size] as? NSNumber)
    #expect(changedAttributes[.modificationDate] as? Date == timestamp)
    #expect(try FileRevisionReader.read(f.files[0]) == originalRevision)
    let (requestB, freshB) = try await f.load()
    let after = await f.pipeline.diagnostics()
    let ticketB = try #require(try await f.disk.prepare(requestB))
    #expect(requestB.renderKey == requestA.renderKey)
    #expect(ticketB.sourceSHA256 != ticketA.sourceSHA256)
    #expect(freshB.image !== warmA.image)
    #expect(try rgba(freshB.image) == rgba(expectedB.image))
    #expect(after.memoryCache?.hits == before.memoryCache?.hits)
    #expect(f.decoder.count == 2)
    let decoder = CacheCountingDecoder()
    let restarted = ImageIOPipeline(decoder: decoder, thumbnailCache: ThumbnailDiskCache(directory: f.cacheDirectory))
    let (_, durableB) = try await f.load(pipeline: restarted)
    #expect(try rgba(durableB.image) == rgba(expectedB.image))
    #expect(decoder.count == 0)
    let (_, memoryB) = try await f.load()
    #expect(memoryB.image === freshB.image)
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == (before.memoryCache?.hits ?? 0) + 1)
}

@Test func issue452NativeWarmGenerationRejectsOldProof() async throws {
    let f = try await Issue452ProofFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let (request, warm, before) = try await f.warm()
    let old = try #require(try await f.disk.prepare(request))
    try await f.disk.clear()
    let current = try #require(try await f.disk.prepare(request))
    #expect(current.generation > old.generation)
    #expect(await f.disk.diagnostics().entries == 0)
    let (_, rebuilt) = try await f.load()
    #expect(try rgba(rebuilt.image) == rgba(warm.image))
    #expect(rebuilt.image !== warm.image)
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == before.memoryCache?.hits)
    #expect(f.decoder.count == 2)
    let (_, next) = try await f.load()
    #expect(next.image === rebuilt.image)
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == (before.memoryCache?.hits ?? 0) + 1)
}

@Test func issue452RevokedCurrentRequestCannotHitNativeMemory() async throws {
    let f = try await Issue452ProofFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let authority = AccessWorkAuthority(), old = AccessWorkAuthority()
    let permit = authority.permit(counter: 0)
    let (_, warm, before) = try await f.warm(permit: permit)
    authority.update(counter: 1, readable: false)
    do { _ = try await f.load(permit: permit); Issue.record("revoked current request returned native memory pixels") }
    catch { #expect(error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled) }
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == before.memoryCache?.hits)
    #expect(f.decoder.count == 1)
    #expect(f.scope.counts[0] == f.scope.counts[1])
    #expect(await f.pipeline.diagnostics().budget?.staging == 0)
    #expect(!permit.isCurrent)
    authority.update(counter: 1, readable: true)
    let current = authority.permit(counter: 1)
    let (_, recovered) = try await f.load(permit: current)
    #expect(recovered.image === warm.image)
    #expect(recovered.accessPermit?.canCoalesce(with: current) == true)
    #expect(recovered.accessPermit?.canCoalesce(with: old.permit(counter: 0)) == false)
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == (before.memoryCache?.hits ?? 0) + 1)
}

@Test(arguments: ["denied", "missing", "corrupt"])
func issue452NativeWarmProofStillChecksPayloadFailure(_ condition: String) async throws {
    let f = try await Issue452ProofFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
    let (request, warm, before) = try await f.warm(permit: permit)
    let ticket = try #require(try await f.disk.prepare(request))
    let payload = f.cacheDirectory.appendingPathComponent(ticket.key.filename + ".png")
    if condition == "denied" {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: payload.path)
    } else if condition == "missing" { try FileManager.default.removeItem(at: payload) }
    else { try Data([1, 2, 3]).write(to: payload) }
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path) }
    if condition == "denied" {
        do { _ = try await f.load(permit: permit); Issue.record("native warm proof hid payload refusal") }
        catch { #expect(AccessReadFailure.isPermissionDenied(error)) }
        #expect(f.decoder.count == 1)
    } else {
        let (_, repaired) = try await f.load(permit: permit)
        #expect(try rgba(repaired.image) == rgba(warm.image))
        #expect(f.decoder.count == 2)
        #expect(try await f.disk.load(ticket) != nil)
    }
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == before.memoryCache?.hits)
    #expect(permit.isCurrent)
    #expect(f.scope.counts[0] == f.scope.counts[1])
}

@Test(.timeLimit(.minutes(2)), arguments: ["cancel", "revoke"], [false, true])
func issue452TemporaryValidationPinReleasesOnInterruption(_ interruption: String, displayPinned: Bool) async throws {
    let pause = Issue452ValidationPause()
    let f = try await Issue452ProofFixture.make(pause: pause)
    defer { try? FileManager.default.removeItem(at: f.base) }
    let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
    let (request, warm, before) = try await f.warm(permit: permit)
    let key = try #require(request.renderKey)
    let started = StartedTasks()
    var presentationOwned = false
    try await withAsyncTeardown {
        if displayPinned {
            try #require(await f.pipeline.pin(key, image: warm))
            presentationOwned = true
        }
        await pause.arm()
        let pending = started.track(Task { try await f.load(permit: permit) })
        try await waitUntil { await pause.entered }
        #expect(await f.pipeline.cache.pinCount(for: key) == (displayPinned ? 2 : 1))
        await f.pipeline.memoryPressure(.critical)
        #expect(await f.pipeline.diagnostics().memoryCache?.entries == 1)
        if interruption == "cancel" { pending.cancel() }
        else { authority.update(counter: 1, readable: false) }
        await pause.release()
        do { _ = try await pending.value; Issue.record("interrupted native validation returned pixels") }
        catch { #expect(error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled) }
        #expect(await f.pipeline.cache.pinCount(for: key) == (displayPinned ? 1 : 0))
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == before.memoryCache?.hits)
        #expect(await f.pipeline.diagnostics().budget?.staging == 0)
        if displayPinned { await f.pipeline.unpin(key); presentationOwned = false }
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(await f.pipeline.diagnostics().memoryCache?.entries == 0)
        #expect(await f.pipeline.diagnostics().budget?.pinned == 0)
        #expect(f.scope.counts[0] == f.scope.counts[1])
        await f.pipeline.memoryPressure(.normal)
        authority.update(counter: 1, readable: true)
        let current = authority.permit(counter: 1)
        let (_, unrelated) = try await f.load(1, permit: current)
        let expected = try ImageIODecoder().decode(ImageDecodeRequest(fileURL: f.files[1], maximumPixelSize: 64))
        #expect(try rgba(unrelated.image) == rgba(expected.image))
        #expect(f.decoder.count == 2)
        #expect(await f.pipeline.diagnostics().budget?.staging == 0)
    } teardown: {
        started.cancelAll(); await pause.release()
        await started.awaitAll(releasing: { await pause.release() })
        if presentationOwned { await f.pipeline.unpin(key); presentationOwned = false }
    }
}

@Test(.timeLimit(.minutes(2)))
func issue452ClearDuringNativeValidationRejectsOldCandidate() async throws {
    let pause = Issue452ValidationPause()
    let f = try await Issue452ProofFixture.make(pause: pause)
    defer { try? FileManager.default.removeItem(at: f.base) }
    let (request, warm, before) = try await f.warm()
    let key = try #require(request.renderKey)
    let old = try #require(try await f.disk.prepare(request))
    let started = StartedTasks()
    try await withAsyncTeardown {
        await pause.arm()
        let pending = started.track(Task { try await f.load() })
        try await waitUntil { await pause.entered }
        #expect(await f.pipeline.cache.pinCount(for: key) == 1)
        let clearer = ThumbnailDiskCache(directory: f.cacheDirectory)
        try await clearer.clear()
        let current = try #require(try await f.disk.prepare(request))
        #expect(current.generation > old.generation)
        await pause.release()
        let (_, fallback) = try await pending.value
        #expect(try rgba(fallback.image) == rgba(warm.image))
        #expect(fallback.image !== warm.image)
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == before.memoryCache?.hits)
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(await f.pipeline.diagnostics().budget?.staging == 0)
        #expect(f.decoder.count == 2)
        #expect(f.scope.counts[0] == f.scope.counts[1])
        let (_, rebuilt) = try await f.load()
        let (_, next) = try await f.load()
        #expect(next.image === rebuilt.image)
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == (before.memoryCache?.hits ?? 0) + 1)
    } teardown: {
        started.cancelAll(); await pause.release()
        await started.awaitAll(releasing: { await pause.release() })
    }
}
