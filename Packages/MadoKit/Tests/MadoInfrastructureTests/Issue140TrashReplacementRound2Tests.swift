import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private struct Issue140InodeResourceReader: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let volume = attributes[.systemNumber], let inode = attributes[.systemFileNumber] else { return nil }
        return FileResourceIdentity(volumeUUID: String(describing: volume), fileIdentifier: String(describing: inode))
    }
}

private final class Issue140ForcedTrashBookmark: BookmarkCoding, @unchecked Sendable {
    private let system: SystemSecurityScope
    private let lock = NSLock()
    private var destination: URL?
    init(system: SystemSecurityScope) { self.system = system }
    func moveResolution(to url: URL?) { lock.withLock { destination = url } }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if let destination = lock.withLock({ destination }) {
            return ResolvedBookmark(url: destination, stale: false)
        }
        return try system.resolve(data)
    }
}

private struct Issue140AlwaysStartedScope: SecurityScope {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
}

#if MADO_TRASH_INTEGRATION
// #672: real DesktopServices Trash; runs only in `node scripts/tdd/trash-lane.mjs`.
@Test(.timeLimit(.minutes(2))) func issue140TrashedOldInodeYieldsToLiveSamePathReplacement() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: fixture("landscape-3x2.png"), to: file)
    let reader = Issue140InodeResourceReader()
    let originalResource = try #require(try reader.identity(for: file))
    let scope = SystemSecurityScope()
    let bookmarks = Issue140ForcedTrashBookmark(system: scope)
    let access = try FileAccess(scope: scope, bookmarks: bookmarks,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-r2-replacement",
        resourceReader: reader)
    let source = try await AccessImageSource.open(.fileGrant(file), access: access,
        pipeline: ImageIOPipeline())
    let (firstRequest, firstImage) = try await source.image(maximumPixelSize: 64)
    var trashed: NSURL?
    try fm.trashItem(at: file, resultingItemURL: &trashed)
    defer { if let trashed { try? fm.removeItem(at: trashed as URL) } }
    #expect(trashed != nil)
    bookmarks.moveResolution(to: trashed as URL?)
    try fm.copyItem(at: fixture("portrait-2x3.png"), to: file)
    #expect(try reader.identity(for: file) != originalResource)
    let next = try? await source.image(maximumPixelSize: 64)
    #expect(next != nil)
    if let (request, image) = next {
        #expect(request.fileURL.standardizedFileURL == file.standardizedFileURL)
        #expect(request.renderKey?.revision != firstRequest.renderKey?.revision)
        #expect(try rgba(image.image) != rgba(firstImage.image))
    }
    await source.close()
}

@Test(.timeLimit(.minutes(2))) func issue140UnreadableSamePathReplacementNeedsReconnection() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: fixture("landscape-3x2.png"), to: file)
    let bookmarks = Issue140ForcedTrashBookmark(system: SystemSecurityScope())
    let access = try FileAccess(scope: Issue140AlwaysStartedScope(), bookmarks: bookmarks,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-r2-unreadable",
        resourceReader: Issue140InodeResourceReader())
    let lease = try await access.acquire(.fileGrant(file))
    await access.release(lease)
    var trashed: NSURL?
    try fm.trashItem(at: file, resultingItemURL: &trashed)
    defer { if let trashed { try? fm.removeItem(at: trashed as URL) } }
    bookmarks.moveResolution(to: trashed as URL?)
    try fm.copyItem(at: fixture("portrait-2x3.png"), to: file)
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    #expect(fm.fileExists(atPath: file.path) && !fm.isReadableFile(atPath: file.path))
    await #expect(throws: FileAccessError.needsFileReconnection(file)) {
        _ = try await access.resolveFileGrant(file)
    }
}
#endif

/// #672 deterministic replacement: the old inode leaves the path and its bookmark resolves into Trash.
@Test(.timeLimit(.minutes(2))) func issue140TrashFactOldInodeYieldsToLiveSamePathReplacement() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: fixture("landscape-3x2.png"), to: file)
    let reader = Issue140InodeResourceReader()
    let originalResource = try #require(try reader.identity(for: file))
    let scope = SystemSecurityScope()
    let bookmarks = TrashFactBookmarks(system: scope)
    let access = try FileAccess(scope: scope, bookmarks: bookmarks,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-r2-replacement-fact",
        resourceReader: reader)
    let source = try await AccessImageSource.open(.fileGrant(file), access: access,
        pipeline: ImageIOPipeline())
    let (firstRequest, firstImage) = try await source.image(maximumPixelSize: 64)
    try fm.moveItem(at: file, to: base.appendingPathComponent("former-inode.png"))
    bookmarks.moveResolution(to: try TrashFacts.syntheticTrashURL("image.png"))
    try fm.copyItem(at: fixture("portrait-2x3.png"), to: file)
    #expect(try reader.identity(for: file) != originalResource)
    let next = try? await source.image(maximumPixelSize: 64)
    #expect(next != nil)
    if let (request, image) = next {
        #expect(request.fileURL.standardizedFileURL == file.standardizedFileURL)
        #expect(request.renderKey?.revision != firstRequest.renderKey?.revision)
        #expect(try rgba(image.image) != rgba(firstImage.image))
    }
    await source.close()
}

/// #672 deterministic replacement for the unreadable same-path case.
@Test(.timeLimit(.minutes(2))) func issue140TrashFactUnreadableSamePathReplacementNeedsReconnection() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: fixture("landscape-3x2.png"), to: file)
    let bookmarks = TrashFactBookmarks()
    let access = try FileAccess(scope: Issue140AlwaysStartedScope(), bookmarks: bookmarks,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-r2-unreadable-fact",
        resourceReader: Issue140InodeResourceReader())
    let lease = try await access.acquire(.fileGrant(file))
    await access.release(lease)
    try fm.moveItem(at: file, to: base.appendingPathComponent("former-inode.png"))
    bookmarks.moveResolution(to: try TrashFacts.syntheticTrashURL("image.png"))
    try fm.copyItem(at: fixture("portrait-2x3.png"), to: file)
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    #expect(fm.fileExists(atPath: file.path) && !fm.isReadableFile(atPath: file.path))
    await #expect(throws: FileAccessError.needsFileReconnection(file)) {
        _ = try await access.resolveFileGrant(file)
    }
}
