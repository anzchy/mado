import Foundation
import Testing
import PicseeCore
import PicseeInfrastructure

private final class Delivered507Scopes: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = [], stopped: [String] = []
    func start(_ url: URL) { lock.withLock { started.append(url.path) } }
    func stop(_ url: URL) { lock.withLock { stopped.append(url.path) } }
    var starts: [String] { lock.withLock { started } }
    var stops: [String] { lock.withLock { stopped } }
}

/// Real scope and bookmarks; a case may force the selection's start result or its readability.
private struct Delivered507Scope: SecurityScope, BookmarkCoding {
    let scopes = Delivered507Scopes()
    var startable = true
    var readable = true
    let system = SystemSecurityScope()
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
    func start(_ url: URL) -> Bool {
        guard startable, system.start(url) else { return false }
        scopes.start(url); return true
    }
    func stop(_ url: URL) { scopes.stop(url); system.stop(url) }
    func isReadable(_ url: URL) -> Bool { readable && system.isReadable(url) }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { try system.resolve(data) }
}

private struct Delivered507Fixture {
    let base: URL, actual: URL, link: URL, image: URL
    init() throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("delivered507-\(UUID())", isDirectory: true)
        actual = base.appendingPathComponent("actual", isDirectory: true)
        link = URL(fileURLWithPath: base.appendingPathComponent("link").path, isDirectory: false)
        image = actual.appendingPathComponent("0.png")
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: actual)
        try Data([1, 2, 3]).write(to: image)
    }
    func files(_ scope: Delivered507Scope) throws -> FileAccess {
        try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue507-delivered")
    }
    var canonicalActual: [String] { actual.resolvingSymlinksInPath().standardizedFileURL.pathComponents }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Test(arguments: ["raw symlink", "plain folder without hint"])
func issue507DeliveredFolderNamesItsCanonicalDirectory(input: String) async throws {
    let f = try Delivered507Fixture()
    defer { f.remove() }
    let scope = Delivered507Scope()
    let files = try f.files(scope)
    let url = input == "raw symlink" ? f.link : URL(fileURLWithPath: f.actual.path, isDirectory: false)
    #expect(!url.hasDirectoryPath)
    let target = try #require(await files.deliveredFolder(url))
    #expect(target.hasDirectoryPath)
    #expect(target.pathComponents == f.canonicalActual)
    #expect(target.path == target.resolvingSymlinksInPath().path, "The target must already be canonical")
    #expect(scope.scopes.starts.count == scope.scopes.stops.count)
    // Readable without a scope (#233): FileAccess starts scopes only for what it must.
    #expect(scope.scopes.starts.isEmpty)
    // Classification never grants: only the folder panel creates an Access Root.
    #expect(await files.records().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("roots.json").path))
}

@Test(arguments: ["image", "file symlink", "dangling symlink", "non-file URL"])
func issue507DeliveredNonFolderIsNotAFolder(input: String) async throws {
    let f = try Delivered507Fixture()
    defer { f.remove() }
    let fm = FileManager.default
    let url: URL
    switch input {
    case "image": url = f.image
    case "file symlink":
        url = f.base.appendingPathComponent("file-link")
        try fm.createSymbolicLink(at: url, withDestinationURL: f.image)
    case "dangling symlink":
        url = f.base.appendingPathComponent("dangling")
        try fm.createSymbolicLink(at: url, withDestinationURL: f.base.appendingPathComponent("absent"))
    default: url = try #require(URL(string: "https://example.com/folder/"))
    }
    let scope = Delivered507Scope()
    let files = try f.files(scope)
    #expect(await files.deliveredFolder(url) == nil)
    #expect(scope.scopes.starts.count == scope.scopes.stops.count)
    if input == "non-file URL" { #expect(scope.scopes.starts.isEmpty) }
}

@Test(arguments: [true, false])
func issue507UnstartableSelectionNeedsProcessReadability(readable: Bool) async throws {
    let f = try Delivered507Fixture()
    defer { f.remove() }
    var scope = Delivered507Scope()
    scope.startable = false
    scope.readable = readable
    let files = try f.files(scope)
    let target = await files.deliveredFolder(f.link)
    if readable { #expect(target?.pathComponents == f.canonicalActual) }
    else { #expect(target == nil) }
    #expect(scope.scopes.stops.isEmpty, "A failed start is never stopped")
}

@Test func issue507UnreadableStartableSelectionTakesItsScopeOnce() async throws {
    let f = try Delivered507Fixture()
    defer { f.remove() }
    var scope = Delivered507Scope()
    scope.readable = false
    let files = try f.files(scope)
    #expect(await files.deliveredFolder(f.link)?.pathComponents == f.canonicalActual)
    #expect(scope.scopes.starts == [f.link.path])
    #expect(scope.scopes.stops == [f.link.path])
}
