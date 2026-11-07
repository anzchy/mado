import CoreGraphics
import Foundation
import Testing
import MadoApplication
import MadoCore
@testable import MadoInfrastructure

private struct SnapshotRig {
    let folder: URL, root: ItemIdentityRoot
    init(files: [String] = ["image.png"]) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: folder.appendingPathComponent(name)) }
        root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    }
    func file(_ name: String = "image.png") -> URL { folder.appendingPathComponent(name) }
    var cacheDirectory: URL { folder.appendingPathComponent("cache") }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// Holds every decode until released, one release per decode.
private final class HeldDecoder: ImageDecoding, @unchecked Sendable {
    private let gate = TestGate()
    func release(_ count: Int) { for _ in 0..<count { gate.signal() } }
    func open() { gate.open() }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        gate.wait()
        return try ImageIODecoder().decode(request)
    }
}

private func budgetFigures(_ pipeline: ImageIOPipeline) throws -> DiagnosticsSnapshot.Budget {
    let budget = try #require(pipeline.cache.budget)
    let usage = budget.usage
    return .init(limit: budget.limit, pinned: usage.pinned, evictable: usage.evictable, staging: usage.reserved, peak: budget.peak)
}

@Test func diagnosticsSnapshotMatchesItsSourcesAfterRealLoads() async throws {
    let rig = try SnapshotRig()
    defer { rig.remove() }
    let disk = ThumbnailDiskCache(directory: rig.cacheDirectory)
    let pipeline = ImageIOPipeline(thumbnailCache: disk)
    let request = try await pipeline.request(for: rig.file(), maximumPixelSize: 64, identityRoot: rig.root)
    let image = try await pipeline.image(for: request)
    _ = try await pipeline.image(for: request)

    let snapshot = await pipeline.diagnostics()
    let budget = try budgetFigures(pipeline)
    #expect(snapshot.budget == budget)
    #expect(budget.evictable == image.image.bytesPerRow * image.image.height && budget.pinned == 0 && budget.staging == 0)
    #expect(budget.peak >= budget.evictable && budget.limit == DecodeConfiguration().budget)
    #expect(snapshot.memoryCache == (await pipeline.cache.diagnostics()))
    #expect(snapshot.memoryCache == .init(entries: 1, bytes: budget.evictable, hits: 1, misses: 1))
    #expect(snapshot.decoding == (await pipeline.admission.diagnostics()))
    #expect(snapshot.decoding == .init(running: 0, waiting: 0, finished: 1))

    // Pinning moves the same pixels from evictable to pinned.
    let key = try #require(request.renderKey)
    await pipeline.pin(key, image: image)
    let pinned = await pipeline.diagnostics()
    #expect(pinned.budget == (try budgetFigures(pipeline)))
    #expect(pinned.budget?.pinned == budget.evictable && pinned.budget?.evictable == 0)
}

@Test func diagnosticsSnapshotCarriesTheWholeDiskGroup() async throws {
    let rig = try SnapshotRig()
    defer { rig.remove() }
    let disk = ThumbnailDiskCache(directory: rig.cacheDirectory)
    let pipeline = ImageIOPipeline(thumbnailCache: disk)
    let request = try await pipeline.request(for: rig.file(), maximumPixelSize: 64, identityRoot: rig.root)
    let ticket = try #require(try await disk.prepare(request))
    #expect(try await pipeline.cachedImage(for: ticket) == nil)
    try await disk.store(try await pipeline.image(for: request), for: ticket)
    #expect(try await pipeline.cachedImage(for: ticket) != nil)

    let snapshot = await pipeline.diagnostics()
    #expect(snapshot.diskCache == (await disk.diagnostics()))
    let group = try #require(snapshot.diskCache)
    #expect(group.entries == 1 && (group.storedBytes ?? 0) > 0 && group.hits == 1 && group.misses == 1)
}

@Test(.timeLimit(.minutes(2))) func diagnosticsSnapshotReadsTheQueueWhileDecodesAreHeld() async throws {
    let rig = try SnapshotRig(files: ["a.png", "b.png"])
    defer { rig.remove() }
    let decoder = HeldDecoder()
    defer { decoder.open() }
    // One 64×48 decode (12 288 bytes) fits the 20 000-byte budget; a second must wait for it.
    let pipeline = ImageIOPipeline(decoder: decoder, configuration: DecodeConfiguration(budget: 20_000))
    let loads = ["a.png", "b.png"].map { name in
        Task { try await pipeline.image(for: try await pipeline.request(for: rig.file(name), maximumPixelSize: 64,
                                                                        identityRoot: rig.root)) }
    }
    try await waitUntil { let activity = await pipeline.admission.activity(); return activity.running == 1 && activity.waiting == 1 }
    let held = await pipeline.diagnostics()
    #expect(held.decoding == .init(running: 1, waiting: 1, finished: 0))
    #expect(held.budget?.staging == 12_288)
    decoder.release(2)
    for load in loads { _ = try await load.value }
    let done = await pipeline.diagnostics()
    #expect(done.decoding == .init(running: 0, waiting: 0, finished: 2))
    #expect(done.decoding == (await pipeline.admission.diagnostics()))
}

@Test func diagnosticsSnapshotLeavesAbsentSourcesUnknown() async throws {
    let pipeline = ImageIOPipeline(cache: ImageMemoryCache(capacity: 1 << 20))
    let snapshot = await pipeline.diagnostics()
    #expect(snapshot.budget == nil)
    #expect(snapshot.diskCache == nil)
    #expect(snapshot.memoryCache == .init(entries: 0, bytes: 0, hits: 0, misses: 0))
    #expect(snapshot.decoding == .init(running: 0, waiting: 0, finished: 0))
}

@Test func diagnosticsDiskCacheableThumbnailsUseValidatedMemoryFirst() async throws {
    let rig = try SnapshotRig()
    defer { rig.remove() }
    let disk = ThumbnailDiskCache(directory: rig.cacheDirectory)
    let pipeline = ImageIOPipeline(thumbnailCache: disk)
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: rig.folder.appendingPathComponent("roots.json")), buildSHA: "p307-fix2")
    let root = try await access.grant(folder: rig.folder)
    for _ in 0..<2 {
        let source = try await AccessImageSource.open(.root(root, file: rig.file()), access: access, pipeline: pipeline)
        _ = try await source.image(maximumPixelSize: 64, priority: .visible)
        await source.close()
    }
    // An eligible cold memory miss falls back to disk and fresh decode; the repeat reuses validated memory.
    var snapshot = await pipeline.diagnostics()
    #expect(snapshot.diskCache?.misses == 1 && snapshot.diskCache?.hits == 0)
    #expect(snapshot.memoryCache?.hits == 1 && snapshot.memoryCache?.misses == 1)
    // A load outside the disk cache (here a direct pipeline request, as the viewer's full image) is a memory lookup.
    _ = try await pipeline.image(for: try await pipeline.request(for: rig.file(), maximumPixelSize: 2048, identityRoot: rig.root))
    snapshot = await pipeline.diagnostics()
    #expect(snapshot.memoryCache?.misses == 2)
}

@Test func diagnosticsViewerImagesUpTo1024UseValidatedMemoryAndLargerUseOrdinaryMemory() async throws {
    let rig = try SnapshotRig()
    defer { rig.remove() }
    let disk = ThumbnailDiskCache(directory: rig.cacheDirectory)
    let pipeline = ImageIOPipeline(thumbnailCache: disk)
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: rig.folder.appendingPathComponent("roots.json")), buildSHA: "p307-fix3")
    let root = try await access.grant(folder: rig.folder)
    func viewerLoad(_ request: AccessRequest, edge: Int) async throws {
        let source = try await AccessImageSource.open(request, access: access, pipeline: pipeline)
        _ = try await source.image(maximumPixelSize: edge)
        await source.close()
    }
    // An eligible fit-size viewer image first misses memory and disk, then hits validated memory.
    try await viewerLoad(.root(root, file: rig.file()), edge: 960)
    try await viewerLoad(.root(root, file: rig.file()), edge: 960)
    var snapshot = await pipeline.diagnostics()
    #expect(snapshot.diskCache?.misses == 1 && snapshot.diskCache?.hits == 0)
    #expect(snapshot.memoryCache?.hits == 1 && snapshot.memoryCache?.misses == 1)
    // Larger than 1024 px (Actual Pixels), or a single file without a folder grant: memory lookups only.
    try await viewerLoad(.root(root, file: rig.file()), edge: 2048)
    try await viewerLoad(.root(root, file: rig.file()), edge: 2048)
    try await viewerLoad(.fileGrant(rig.file()), edge: 960)
    snapshot = await pipeline.diagnostics()
    #expect(snapshot.memoryCache?.misses == 3 && snapshot.memoryCache?.hits == 2)
    #expect(snapshot.diskCache?.misses == 1 && snapshot.diskCache?.hits == 0)
}
