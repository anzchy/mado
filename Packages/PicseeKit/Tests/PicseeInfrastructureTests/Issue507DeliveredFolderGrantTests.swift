import Foundation
import Testing
import PicseeCore
import PicseeInfrastructure

private final class Delivered507Stops: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Force only the native selected URL's start result; actual bookmark and file operations stay real.
private struct Delivered507Access: SecurityScope, BookmarkCoding {
    let selected: URL
    let target: URL
    let stops: Delivered507Stops
    var denyRead = false
    var rejectBookmark = false
    var redirectBookmark: URL?
    let system = SystemSecurityScope()
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
    func start(_ url: URL) -> Bool {
        url.standardizedFileURL.path == selected.standardizedFileURL.path ? false : system.start(url)
    }
    func stop(_ url: URL) {
        if url.standardizedFileURL.path == selected.standardizedFileURL.path { stops.record() }
        else { system.stop(url) }
    }
    func isReadable(_ url: URL) -> Bool { !denyRead && system.isReadable(url) }
    func create(for url: URL) throws -> Data {
        if rejectBookmark && url.resolvingSymlinksInPath().path == target.path {
            throw CocoaError(.fileReadNoPermission)
        }
        return try system.create(for: url)
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let resolved = try system.resolve(data)
        if let redirectBookmark, resolved.url.resolvingSymlinksInPath().path == target.path {
            return ResolvedBookmark(url: redirectBookmark, stale: false)
        }
        return resolved
    }
}

@Test func issue507DeliveredFolderUsesRealBookmarkAndKeepsSelectionBoundary() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("delivery507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual", isDirectory: true)
    let selected = base.appendingPathComponent("selected-link")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: selected, withDestinationURL: actual)
    let bytes = Data([5, 0, 7])
    try bytes.write(to: actual.appendingPathComponent("image.png"))
    let sibling = base.appendingPathComponent("sibling.png")
    try bytes.write(to: sibling)
    let stops = Delivered507Stops()
    let adapter = Delivered507Access(selected: selected, target: actual, stops: stops)
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let files = try FileAccess(scope: adapter, bookmarks: adapter, store: store, buildSHA: "issue507-delivered")
    // The ordinary panel API must remain strict even for a readable selection.
    await #expect(throws: FileAccessError.startFailed) { try await files.grant(folder: selected) }
    #expect(await files.records().isEmpty)
    #expect(try store.load().isEmpty)
    let id = try await files.grantDeliveredFolder(selected)
    let verified = try await files.verifyExplicitSelection(id)
    #expect(verified.resolvingSymlinksInPath().path == actual.path)
    #expect(await files.records().count == 1)
    #expect(try store.load().count == 1)
    let image = selected.appendingPathComponent("image.png")
    let read = try await files.withLease(.root(id, file: image)) { _ in try Data(contentsOf: image) }
    #expect(read == bytes)
    await #expect(throws: FileAccessError.outsideRoot) { try await files.withLease(.root(id, file: sibling)) { _ in true } }
    #expect(await files.rootCovering(sibling) == nil)
    #expect(stops.value == 0)
    // Reopen the real persisted bookmark rather than relying on the initial readable URL.
    let restored = try FileAccess(scope: adapter, bookmarks: adapter, store: store, buildSHA: "issue507-restored")
    let reopened = try await restored.withLease(.root(id, file: image)) { _ in try Data(contentsOf: image) }
    #expect(reopened == bytes)
}

@Test(arguments: ["bookmark", "missing", "denied", "redirect"])
func issue507RejectedDeliveredFolderPreservesExistingAuthority(failure: String) async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("denied507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let existing = base.appendingPathComponent("existing", isDirectory: true)
    let target = base.appendingPathComponent("target", isDirectory: true)
    let selected = base.appendingPathComponent("selected-link")
    try fm.createDirectory(at: existing, withIntermediateDirectories: true)
    if failure != "missing" { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
    try fm.createSymbolicLink(at: selected, withDestinationURL: target)
    let stops = Delivered507Stops()
    let adapter = Delivered507Access(selected: selected, target: target, stops: stops,
        denyRead: failure == "denied", rejectBookmark: failure == "bookmark",
        redirectBookmark: failure == "redirect" ? existing : nil)
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let files = try FileAccess(scope: adapter, bookmarks: adapter, store: store, buildSHA: "issue507-rejected")
    let original = try await files.grant(folder: existing)
    let before = try store.load()
    await #expect(throws: (any Error).self) { try await files.grantDeliveredFolder(selected) }
    #expect(await files.records() == before)
    #expect(try store.load() == before)
    #expect(await files.rootURL(original)?.path == existing.path)
    #expect(await files.rootCovering(selected) == nil)
    #expect(stops.value == 0)
}

/// Model the opaque scope carried by a bookmark-resolved URL without calling
/// System.start/stop on a synthetic capability. Bookmarks and filesystem I/O stay real.
private struct Resolved507CapabilityAccess: SecurityScope, BookmarkCoding {
    let system = SystemSecurityScope()
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
    func start(_ url: URL) -> Bool { url.baseURL != nil }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let resolved = try system.resolve(data)
        // The relative representation marks the resolved capability. Rebuilding a
        // plain canonical path loses that marker, just as it can lose opaque scope.
        let marked = URL(fileURLWithPath: resolved.url.lastPathComponent, isDirectory: true,
                         relativeTo: resolved.url.deletingLastPathComponent())
        return ResolvedBookmark(url: marked, stale: resolved.stale)
    }
}

@Test func issue507RetainsResolvedBookmarkScopeForExplicitVerification() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scope507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual", isDirectory: true)
    let selected = base.appendingPathComponent("selected-link")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: selected, withDestinationURL: actual)
    let image = selected.appendingPathComponent("image.png")
    let bytes = Data([5, 0, 7, 1])
    try bytes.write(to: actual.appendingPathComponent("image.png"))
    let adapter = Resolved507CapabilityAccess()
    let store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
    let files = try FileAccess(scope: adapter, bookmarks: adapter, store: store, buildSHA: "issue507-capability")
    let id = try await files.grantDeliveredFolder(selected)
    let verified = try await files.verifyExplicitSelection(id)
    #expect(verified.resolvingSymlinksInPath().standardizedFileURL.pathComponents ==
        actual.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
    let read = try await files.withLease(.root(id, file: image)) { _ in try Data(contentsOf: image) }
    #expect(read == bytes)
    let restored = try FileAccess(scope: adapter, bookmarks: adapter, store: store, buildSHA: "issue507-capability-restored")
    let reopened = try await restored.verifyExplicitSelection(id)
    #expect(reopened.resolvingSymlinksInPath().standardizedFileURL.pathComponents ==
        actual.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
    let persistedRead = try await restored.withLease(.root(id, file: image)) { _ in try Data(contentsOf: image) }
    #expect(persistedRead == bytes)
}
