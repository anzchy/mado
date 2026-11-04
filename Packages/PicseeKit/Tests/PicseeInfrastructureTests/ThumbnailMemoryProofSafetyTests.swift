import CoreGraphics
import Foundation
import ImageIO
import PicseeApplication
import PicseeCore
import Testing
import UniformTypeIdentifiers
@testable import PicseeInfrastructure

/// Stops real cache callbacks after native validation; controllers must not await the cache while held.
private final class Issue452LateTrace: ResourceSnapshotTracing, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = TestGate()
    private var boundary: String?
    private var sawPin = false
    private var arrived = false
    var entered: Bool { lock.withLock { arrived } }
    func arm(_ boundary: String) { lock.withLock { self.boundary = boundary; sawPin = false; arrived = false } }
    func open() { gate.open() }
    func snapshot(_ snapshot: ResourceSnapshot) {
        let stop = lock.withLock { () -> Bool in
            guard boundary == "unpin" else { return false }
            if snapshot.pinnedBytes > 0 { sawPin = true }
            guard sawPin, snapshot.pinnedBytes == 0 else { return false }
            boundary = nil; arrived = true
            return true
        }
        if stop { gate.wait() }
    }
    func lookup(isPreview: Bool, hit: Bool) {
        let stop = lock.withLock { () -> Bool in
            guard boundary == "lookup", hit else { return false }
            boundary = nil; arrived = true
            return true
        }
        if stop { gate.wait() }
    }
}

/// An OS boundary gate on the real FileAccess actor's last scope stop, after Source display cleanup.
private final class Issue452LateScope: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = TestGate()
    private var starts = 0, stops = 0
    private var armed = false, arrived = false
    var counts: [Int] { lock.withLock { [starts, stops] } }
    var entered: Bool { lock.withLock { arrived } }
    func arm() { lock.withLock { armed = true; arrived = false } }
    func open() { gate.open() }
    func isReadable(_ url: URL) -> Bool { false }
    func start(_ url: URL) -> Bool { lock.withLock { starts += 1 }; return true }
    func stop(_ url: URL) {
        let pause = lock.withLock { () -> Bool in
            stops += 1
            guard armed else { return false }
            armed = false; arrived = true
            return true
        }
        if pause { gate.wait() }
    }
}

private struct Issue452LateFixture {
    let base: URL, file: URL, directory: URL
    let root: AccessRootID
    let scope: Issue452LateScope
    let access: FileAccess
    let trace: Issue452LateTrace
    let pipeline: ImageIOPipeline
    let disk: ThumbnailDiskCache
    let decoder: CacheCountingDecoder
    static func make() async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("image.tiff"), directory = base.appendingPathComponent("cache")
        try issue452SolidTIFF(file, red: 1)
        let scope = Issue452LateScope()
        let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "i452-fix1")
        let root = try await access.grant(folder: folder)
        let trace = Issue452LateTrace(), disk = ThumbnailDiskCache(directory: directory), decoder = CacheCountingDecoder()
        let pipeline = ImageIOPipeline(decoder: decoder,
            configuration: DecodeConfiguration(budget: 1_048_576, cacheCapacity: 1_048_576),
            cacheTrace: trace, thumbnailCache: disk)
        return Self(base: base, file: file, directory: directory, root: root, scope: scope,
            access: access, trace: trace, pipeline: pipeline, disk: disk, decoder: decoder)
    }
    func open(_ permit: AccessWorkPermit) async throws -> AccessImageSource {
        try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline, accessPermit: permit)
    }
    func load(_ permit: AccessWorkPermit) async throws -> (ImageDecodeRequest, DecodedImage) {
        let source = try await open(permit)
        do {
            let value = try await source.image(maximumPixelSize: 64, priority: .visible)
            await source.close(); return value
        } catch { await source.close(); throw error }
    }
    func warm(_ permit: AccessWorkPermit) async throws -> (ImageDecodeRequest, DecodedImage) {
        let (_, first) = try await load(permit)
        let result = try await load(permit)
        try #require(first.image === result.1.image)
        try #require(await pipeline.diagnostics().memoryCache?.hits == 1)
        return result
    }
}

// Serialize blocking trace/OS gates so parallel cases cannot exhaust cooperative executor threads.
@Suite(.serialized) private struct Issue452LateDeliveryTests {
@Test(.timeLimit(.minutes(2)), arguments: ["unpin", "lookup"])
func issue452LateClearAfterNativeValidationRejectsOldBuffer(_ boundary: String) async throws {
    let f = try await Issue452LateFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    defer { f.trace.open(); f.scope.open() }
    let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
    let (request, old) = try await f.warm(permit)
    let key = try #require(request.renderKey), started = StartedTasks()
    try await withAsyncTeardown {
        f.trace.arm(boundary)
        let pending = started.track(Task { try await f.load(permit) })
        try await waitUntil { f.trace.entered }
        // The image-memory actor is synchronously blocked; clear only through the independent disk actor.
        try await ThumbnailDiskCache(directory: f.directory).clear()
        f.trace.open()
        let (_, image) = try await pending.value
        #expect(image.image !== old.image)
        #expect(try rgba(image.image) == rgba(old.image))
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == (boundary == "lookup" ? 2 : 1))
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(await f.pipeline.diagnostics().budget?.staging == 0)
        #expect(f.scope.counts[0] == f.scope.counts[1])
        _ = try await f.load(permit)
        let (_, next) = try await f.load(permit)
        #expect(try rgba(next.image) == rgba(old.image))
    } teardown: {
        started.cancelAll(); f.trace.open(); f.scope.open()
        await started.awaitAll()
    }
}

@Test(.timeLimit(.minutes(2)), arguments: ["unpin", "lookup"], ["revoke", "cancel"])
func issue452LateAuthorityLossAfterNativeValidationDeliversNothing(_ boundary: String, transition: String) async throws {
    let f = try await Issue452LateFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    defer { f.trace.open(); f.scope.open() }
    let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
    let (request, _) = try await f.warm(permit)
    let key = try #require(request.renderKey), started = StartedTasks()
    try await withAsyncTeardown {
        f.trace.arm(boundary)
        let pending = started.track(Task { try await f.load(permit) })
        try await waitUntil { f.trace.entered }
        if transition == "revoke" { authority.update(counter: 1, readable: false) }
        else { pending.cancel() }
        f.trace.open()
        do { _ = try await pending.value; Issue.record("late invalidated native request delivered pixels") }
        catch { #expect(error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled) }
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(await f.pipeline.diagnostics().budget?.staging == 0)
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == (boundary == "lookup" ? 2 : 1))
        #expect(f.scope.counts[0] == f.scope.counts[1])
        authority.update(counter: 1, readable: true)
        _ = try await f.load(authority.permit(counter: 1))
    } teardown: {
        started.cancelAll(); f.trace.open(); f.scope.open()
        await started.awaitAll()
    }
}

@Test(.timeLimit(.minutes(2)), arguments: ["clear", "revoke", "cancel"])
func issue452FinalSourceScopeReleaseCannotDeliverInvalidNativePixels(_ transition: String) async throws {
    let f = try await Issue452LateFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    defer { f.trace.open(); f.scope.open() }
    let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
    let (request, old) = try await f.warm(permit)
    let key = try #require(request.renderKey), started = StartedTasks()
    let source = try await f.open(permit)
    try await withAsyncTeardown {
        f.trace.arm("unpin")
        let pending = started.track(Task { try await source.image(maximumPixelSize: 64, priority: .visible) })
        try await waitUntil { f.trace.entered }
        await source.close() // Pending image still owns the display lease until Source's final cleanup.
        f.scope.arm()
        f.trace.open()
        try await waitUntil { f.scope.entered }
        // FileAccess is blocked inside the OS stop callback; do not await that actor until release.
        if transition == "clear" { try await ThumbnailDiskCache(directory: f.directory).clear() }
        else if transition == "revoke" { authority.update(counter: 1, readable: false) }
        else { pending.cancel() }
        f.scope.open()
        if transition == "clear" {
            let (_, image) = try await pending.value
            #expect(image.image !== old.image)
            #expect(try rgba(image.image) == rgba(old.image))
        } else {
            do { _ = try await pending.value; Issue.record("Source's final awaited cleanup delivered invalid native pixels") }
            catch { #expect(error is CancellationError || (error as? ImageLoadError)?.kind == .cancelled) }
        }
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(await f.pipeline.diagnostics().budget?.staging == 0)
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == 2) // Lookup resolved before the final scope stop.
        #expect(f.scope.counts[0] == f.scope.counts[1])
    } teardown: {
        started.cancelAll(); f.trace.open(); f.scope.open()
        await started.awaitAll()
        await source.close()
    }
}

@Test(.timeLimit(.minutes(2)))
func issue452FinalSourceGenerationRetryUsesCurrentDiskPayload() async throws {
    let f = try await Issue452LateFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    defer { f.trace.open(); f.scope.open() }
    let authority = AccessWorkAuthority(), permit = authority.permit(counter: 0)
    let (request, old) = try await f.warm(permit)
    let key = try #require(request.renderKey), started = StartedTasks()
    let oldTicket = try await f.access.withLease(.root(f.root, file: f.file)) { _ in
        try #require(try await f.disk.prepare(request))
    }
    let before = await f.pipeline.diagnostics()
    let source = try await f.open(permit)
    try await withAsyncTeardown {
        f.trace.arm("unpin")
        let pending = started.track(Task { try await source.image(maximumPixelSize: 64, priority: .visible) })
        try await waitUntil { f.trace.entered }
        await source.close()
        f.scope.arm()
        f.trace.open()
        try await waitUntil { f.scope.entered }
        let disk = ThumbnailDiskCache(directory: f.directory)
        try await disk.clear()
        // Restore the same persisted grant in a separate real FileAccess actor: the original actor is
        // blocked in scope.stop. This preserves the request's authorized root ID and physical source.
        let seedScope = CountingScope()
        let seeder = try FileAccess(scope: seedScope, bookmarks: FakeBookmarks(),
            store: BookmarkStore(url: f.base.appendingPathComponent("roots.json")), buildSHA: "i452-fix1-seed")
        try await seeder.withLease(.root(f.root, file: f.file)) { lease in
            #expect(lease.rootID == f.root)
            #expect(lease.url.resolvingSymlinksInPath().standardizedFileURL == f.file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL)
            let current = try #require(try await disk.prepare(request))
            try #require(current.generation > oldTicket.generation)
            // The source has not changed; storeForMemory independently verifies these real pixels
            // against the current source digest/revision before publishing the new-generation row.
            try #require(try await disk.storeForMemory(old, for: current))
        }
        #expect(seedScope.counts[0] == seedScope.counts[1])
        #expect(await disk.diagnostics().entries == 1)
        f.scope.open()
        let (_, image) = try await pending.value
        #expect(image.image !== old.image)
        #expect(try rgba(image.image) == rgba(old.image))
        #expect(f.decoder.count == 1)
        let after = await f.pipeline.diagnostics()
        #expect(after.diskCache?.hits == (before.diskCache?.hits ?? 0) + 1)
        #expect(after.memoryCache?.misses == before.memoryCache?.misses)
        #expect(after.memoryCache?.hits == (before.memoryCache?.hits ?? 0) + 1)
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(after.budget?.staging == 0)
        #expect(f.scope.counts[0] == f.scope.counts[1])
        let (_, next) = try await f.load(permit)
        #expect(next.image === image.image)
        #expect(f.decoder.count == 1)
        #expect(await f.pipeline.diagnostics().memoryCache?.hits == (after.memoryCache?.hits ?? 0) + 1)
        #expect(await f.pipeline.cache.pinCount(for: key) == 0)
        #expect(f.scope.counts[0] == f.scope.counts[1])
    } teardown: {
        started.cancelAll(); f.trace.open(); f.scope.open()
        await started.awaitAll()
        await source.close()
    }
}

}

@Test func issue452OrdinaryPipelineCannotConsumeLeaseBoundThumbnail() async throws {
    let f = try await Issue452ProofFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let (request, native, before) = try await f.warm()
    let ordinary = try await f.pipeline.image(for: request)
    let after = await f.pipeline.diagnostics()
    #expect(ordinary.image !== native.image)
    #expect(try rgba(ordinary.image) == rgba(native.image))
    #expect(f.decoder.count == 2)
    #expect(after.memoryCache?.hits == before.memoryCache?.hits)
    #expect(after.diskCache?.hits == before.diskCache?.hits)
    #expect(await f.pipeline.cache.pinCount(for: try #require(request.renderKey)) == 0)
    #expect(after.budget?.staging == 0)
    _ = try await f.load()
    let (_, again) = try await f.load()
    #expect(try rgba(again.image) == rgba(native.image))
}

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
    #expect(await f.pipeline.cache.pinCount(for: try #require(request.renderKey)) == 0)
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

@Test func issue452CachedImageWrapperPreservesValidNativeMemory() async throws {
    let f = try await Issue452ProofFixture.make()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let (request, native, before) = try await f.warm()
    let image = try await f.access.withLease(.root(f.root, file: f.files[0])) { _ in
        let ticket = try #require(try await f.disk.prepare(request))
        return try await f.pipeline.cachedImage(for: ticket)
    }
    #expect(try #require(image).image === native.image)
    #expect(await f.pipeline.diagnostics().memoryCache?.hits == (before.memoryCache?.hits ?? 0) + 1)
    #expect(f.decoder.count == 1)
    #expect(await f.pipeline.cache.pinCount(for: try #require(request.renderKey)) == 0)
    #expect(f.scope.counts[0] == f.scope.counts[1])
}
