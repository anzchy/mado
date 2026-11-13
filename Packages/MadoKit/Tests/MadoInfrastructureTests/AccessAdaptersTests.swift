import Foundation
import Testing
import MadoCore
import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func accessSiblingListingSkipsHiddenNestedAndOutsideLinks() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("root")
    let nested = root.appendingPathComponent("nested")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    for name in ["image10.jpg", "image2.png", ".hidden.jpg", "notes.txt"] {
        try Data().write(to: root.appendingPathComponent(name))
    }
    try Data().write(to: nested.appendingPathComponent("nested.jpg"))
    let outside = base.appendingPathComponent("outside.jpg")
    try Data().write(to: outside)
    try fm.createSymbolicLink(at: root.appendingPathComponent("escape.jpg"), withDestinationURL: outside)
    try fm.createSymbolicLink(at: root.appendingPathComponent("inside.jpg"), withDestinationURL: root.appendingPathComponent("image2.png"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("outside-folder"), withDestinationURL: base)
    let lister = SiblingLister()
    let names = try await lister.images(in: root, root: root).map(\.lastPathComponent).sorted()
    #expect(names == ["image10.jpg", "image2.png", "inside.jpg"])
    await #expect(throws: FileAccessError.outsideRoot) { try await lister.images(in: base, root: root) }
}

@Test func accessSystemAdapterCreatesAndResolvesRealBookmark() throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let adapter = SystemSecurityScope()
    let bookmark = try adapter.create(for: folder)
    #expect(!bookmark.isEmpty)
    let result = try adapter.resolve(bookmark)
    #expect(result.url.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    #expect(!result.stale)
    // Unsandboxed execution exercises Foundation forwarding, not powerbox permission or cross-signature restore.
    let started = adapter.start(result.url)
    if started { adapter.stop(result.url) }
    #expect(throws: (any Error).self) { try adapter.resolve(Data("broken".utf8)) }
}

@Test func issue140SystemFileBookmarkFollowsSameVolumeRename() throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let original = folder.appendingPathComponent("old.png")
    let renamed = folder.appendingPathComponent("new.png")
    try Data([1, 2, 3]).write(to: original)
    let adapter = SystemSecurityScope()
    let bookmark = try adapter.create(for: original)
    try fm.moveItem(at: original, to: renamed)
    let result = try adapter.resolve(bookmark)
    #expect(result.url.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
    #expect(try Data(contentsOf: result.url) == Data([1, 2, 3]))
}

@Test(.timeLimit(.minutes(2))) func issue73SystemScopeReadabilityReflectsRealFiles() async throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let file = tree.appendingPathComponent("readable.png"), missing = tree.appendingPathComponent("missing.png")
    let bytes = Data([0, 1, 2, 255])
    try bytes.write(to: file)
    let scope = SystemSecurityScope()
    #expect(scope.isReadable(file))
    #expect(!scope.isReadable(missing))
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "issue73-system")
    let readback = try await access.withLease(.fileGrant(file)) { lease in
        #expect(lease.url == file && lease.rootID == nil)
        return try Data(contentsOf: lease.url)
    }
    #expect(readback == bytes)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(await access.records().isEmpty)
}
