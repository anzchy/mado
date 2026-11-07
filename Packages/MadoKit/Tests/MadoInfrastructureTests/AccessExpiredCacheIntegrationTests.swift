import Foundation
import Testing
import MadoApplication
import MadoCore
@testable import MadoInfrastructure

/// Permission refusal must stay observable even when both cache tiers already
/// hold valid pixels. Missing or damaged payloads remain ordinary cache misses.
@Test(.timeLimit(.minutes(2)), arguments: ["denied", "missing", "corrupt"])
func t230WarmMemoryCannotHideRealPayloadPermissionFailure(_ condition: String) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = base.appendingPathComponent("Root", isDirectory: true)
    let cacheFolder = base.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = folder.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let scope = CountingScope()
    let files = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T230-cache")
    let root = try await files.grant(folder: folder)
    let authority = AccessWorkAuthority()
    let permit = authority.permit(counter: 0)
    let disk = ThumbnailDiskCache(directory: cacheFolder)
    let memory = ImageMemoryCache(capacity: 1_000_000)
    let decoder = CacheCountingDecoder()
    let pipeline = ImageIOPipeline(decoder: decoder, cache: memory, thumbnailCache: disk)
    let initial = try await AccessImageSource.open(.root(root, file: file), access: files,
        pipeline: pipeline, accessPermit: permit)
    let (request, expected) = try await initial.image(maximumPixelSize: 64)
    await initial.close()
    // AccessImageSource intentionally decodes fresh on a durable miss. Warm the
    // independent memory path under a real lease, then prove both tiers have pixels.
    _ = try await files.withLease(.root(root, file: file)) { _ in
        try await pipeline.image(for: request)
    }
    let ticket = try #require(try await disk.prepare(request))
    #expect(try await disk.load(ticket) != nil)
    #expect(await memory.diagnostics().entries == 1)
    let before = decoder.count
    let payload = cacheFolder.appendingPathComponent(ticket.key.filename + ".png")
    if condition == "denied" {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: payload.path)
    } else if condition == "missing" {
        try FileManager.default.removeItem(at: payload)
    } else {
        try Data([0, 1, 2]).write(to: payload)
    }
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path) }
    let source = try await AccessImageSource.open(.root(root, file: file), access: files,
        pipeline: pipeline, accessPermit: permit)
    if condition == "denied" {
        do {
            _ = try await disk.load(ticket)
            Issue.record("cached payload refusal became a miss")
        } catch { #expect(AccessReadFailure.isPermissionDenied(error)) }
        do {
            _ = try await source.image(maximumPixelSize: 64)
            Issue.record("warm cache delivered fallback pixels after payload refusal")
        } catch { #expect(AccessReadFailure.isPermissionDenied(error)) }
        #expect(decoder.count == before)
        // The readable source root is not itself lost merely because the cache
        // payload was refused. Recovery routing must verify that root separately.
        #expect(permit.isCurrent)
        #expect(await disk.diagnostics().entries == 1)
    } else {
        let (_, image) = try await source.image(maximumPixelSize: 64)
        #expect(try rgba(image.image) == rgba(expected.image))
        #expect(decoder.count == before + 1)
        #expect(try await disk.load(ticket) != nil)
    }
    await source.close()
    #expect(scope.counts[0] == scope.counts[1])
}
