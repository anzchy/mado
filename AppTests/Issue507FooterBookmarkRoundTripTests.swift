import Foundation
import Testing
import MadoCore
import MadoInfrastructure

@Test(arguments: [false, true])
func issue507FooterDirectoryBookmarkPreservesDirectoryHint(existing: Bool) throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("roundtrip507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let selected = base.appendingPathComponent("selected-directory", isDirectory: true)
    if existing { try fm.createDirectory(at: selected, withIntermediateDirectories: true) }
    let adapter = Footer506Bookmarks()
    let resolved = try adapter.resolve(adapter.create(for: selected))
    #expect(resolved.url.hasDirectoryPath)
    #expect(resolved.url == selected)
    #expect(!resolved.stale)
}

@Test func issue507FooterBookmarkVerifiesRawSymlinkParentSelection() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("verify507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let target = base.appendingPathComponent("target", isDirectory: true)
    let deep = target.appendingPathComponent("deep", isDirectory: true)
    let actual = target.appendingPathComponent("actual", isDirectory: true)
    try fm.createDirectory(at: deep, withIntermediateDirectories: true)
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createDirectory(at: base.appendingPathComponent("actual", isDirectory: true), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: deep)
    let spelling = URL(fileURLWithPath: base.path + "/link/../actual/", isDirectory: true)
    let expected = spelling.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    #expect(expected.pathComponents == actual.pathComponents)
    let image = expected.appendingPathComponent("one.png")
    let bytes = Data([5, 0, 6])
    try bytes.write(to: image)
    let adapter = Footer506Bookmarks()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue507-footer")
    let id = try await files.grant(folder: spelling)
    let verified = try await files.verifyExplicitSelection(id)
    #expect(verified.hasDirectoryPath)
    #expect(verified.standardizedFileURL.resolvingSymlinksInPath().pathComponents == expected.pathComponents)
    let read = try await files.withLease(.root(id, file: image)) { _ in try Data(contentsOf: image) }
    #expect(read == bytes)
}
