import Foundation
import Testing
import MadoCore
import MadoInfrastructure

@Test func folderSnapshotResolverIdentity() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let file = root.appendingPathComponent("nested/img2.png")
    try Data().write(to: file)
    let id = AccessRootID()
    let canonical = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    for rootURL in [root, canonical] {
        let scope = ItemIdentityRoot(id: id, url: rootURL)
        let entry = FolderEntry(url: file, root: scope)
        let resolver = FileItemIdentityResolver(root: scope)
        #expect(entry.itemID == .rootRelative(rootID: id, relativePath: "nested/img2.png"))
        #expect(entry.itemID == (try await resolver.identity(for: file)))
        #expect(entry.relativePath == "nested/img2.png")
        #expect(entry.url == file)
        let version = SnapshotVersion(rootID: id, folder: rootURL, generation: 9)
        #expect(version.folder == canonical)
    }
}

@Test func folderSnapshotInwardSymlinkResolverIdentity() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let target = root.appendingPathComponent("nested/img2.png")
    let alias = root.appendingPathComponent("alias.png")
    try Data().write(to: target)
    try fm.createSymbolicLink(at: alias, withDestinationURL: target)
    let scope = ItemIdentityRoot(id: AccessRootID(), url: root)
    let resolver = FileItemIdentityResolver(root: scope)
    let entry = FolderEntry(url: alias, root: scope)
    #expect(entry.itemID == (try await resolver.identity(for: alias)))
    #expect(entry.itemID == (try await resolver.identity(for: target)))
    #expect(entry.itemID == .rootRelative(rootID: scope.id, relativePath: "nested/img2.png"))
    #expect(entry.relativePath == "alias.png")
    #expect(entry.url == alias)
}
