import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

struct IdentityTree {
    let root: URL
    let file: URL
    let id = AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = root.appendingPathComponent("b.png")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: file)
    }
    var scope: ItemIdentityRoot { ItemIdentityRoot(id: id, url: root) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private struct MissingIdentityReader: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        #expect(!Thread.isMainThread)
        return nil
    }
}

private struct NilGrantResourceReader: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { nil }
}

@Test func itemResolverFileGrantWithoutResourceKeepsOneEphemeralTokenPerCanonicalPath() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let grant = FileItemIdentityResolver(reader: NilGrantResourceReader())
    let first = try await grant.identity(for: tree.file)
    let alias = tree.root.appendingPathComponent("a/../b.png")
    let same = try await grant.identity(for: alias)
    let second = try await grant.identity(for: tree.root.appendingPathComponent("other.png"))

    #expect(first.stableEncoding.hasPrefix("id1:ephemeral:"))
    #expect(UUID(uuidString: String(first.stableEncoding.dropFirst("id1:ephemeral:".count))) != nil)
    #expect(same == first)
    #expect(second.stableEncoding.hasPrefix("id1:ephemeral:"))
    #expect(second != first)
}

@Test func itemResolverCanonicalAliasesRenameAndHardLinks() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let resolver = FileItemIdentityResolver(root: tree.scope)
    let original = try await resolver.identity(for: tree.file)
    #expect(original == .rootRelative(rootID: tree.id, relativePath: "b.png"))
    let link = tree.root.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.file)
    for alias in [tree.root.appendingPathComponent("a/../b.png"), link,
                  URL(fileURLWithPath: tree.root.path + "/").appendingPathComponent("b.png")] {
        #expect(try await resolver.identity(for: alias) == original)
    }
    let trailingRoot = FileItemIdentityResolver(root: ItemIdentityRoot(id: tree.id, url: URL(fileURLWithPath: tree.root.path + "/")))
    #expect(try await trailingRoot.identity(for: tree.file) == original)
    let hardLink = tree.root.appendingPathComponent("hard.png")
    try FileManager.default.linkItem(at: tree.file, to: hardLink)
    #expect(try URLIdentityResourceReader().identity(for: hardLink) == URLIdentityResourceReader().identity(for: tree.file))
    // User chose path identity: two simultaneously existing hard-link paths are two items.
    #expect(try await resolver.identity(for: hardLink) != original)
    let other = tree.root.appendingPathComponent("other.png")
    try Data("other".utf8).write(to: other)
    #expect(try await resolver.identity(for: other) != original)
    let renamed = tree.root.appendingPathComponent("renamed.png")
    try FileManager.default.moveItem(at: tree.file, to: renamed)
    #expect(try await resolver.identity(for: renamed) == original)
}

@Test @MainActor func itemResolverMissingResourcesHaveExplicitFallbacks() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let resolver = FileItemIdentityResolver(root: tree.scope, reader: MissingIdentityReader())
    #expect(try await resolver.identity(for: tree.file) == .rootRelative(rootID: tree.id, relativePath: "b.png"))
    let grant = FileItemIdentityResolver(reader: MissingIdentityReader())
    let first = try await grant.identity(for: tree.file)
    #expect(try await grant.identity(for: tree.root.appendingPathComponent("a/../b.png")) == first)
    #expect(first.stableEncoding.hasPrefix("id1:ephemeral:"))
    let other = tree.root.appendingPathComponent("other.png")
    try Data("other".utf8).write(to: other)
    #expect(try await grant.identity(for: other) != first)
    let outside = tree.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
    await #expect(throws: FileAccessError.outsideRoot) { try await resolver.identity(for: outside) }
    // resolvingSymlinksInPath needs an existing target; never overwrite or remove another owner's file.
    let ownsOutside = !FileManager.default.fileExists(atPath: outside.path)
    if ownsOutside { try Data("outside".utf8).write(to: outside, options: .withoutOverwriting) }
    defer { if ownsOutside { try? FileManager.default.removeItem(at: outside) } }
    let escape = tree.root.appendingPathComponent("escape.png")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
    await #expect(throws: FileAccessError.outsideRoot) { try await resolver.identity(for: escape) }
    await #expect(throws: FileAccessError.outsideRoot) { try await grant.identity(for: URL(string: "https://example.invalid/a")!) }
}

private final class OptionalIdentityReader: FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var missing = false
    func makeUnavailable() { lock.withLock { missing = true } }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        if lock.withLock({ missing }) { return nil }
        return try URLIdentityResourceReader().identity(for: fileURL)
    }
}

@Test func itemResolverVacatedNameDoesNotCollideWithRenamedItem() async throws {
    for missing in [false, true] {
        let tree = try IdentityTree(); defer { tree.remove() }
        let reader = OptionalIdentityReader()
        let resolver = FileItemIdentityResolver(root: tree.scope, reader: reader)
        let original = try await resolver.identity(for: tree.file)
        let renamed = tree.root.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: tree.file, to: renamed)
        #expect(try await resolver.identity(for: renamed) == original)
        if missing { reader.makeUnavailable() }
        try Data("new file".utf8).write(to: tree.file)
        let new = try await resolver.identity(for: tree.file)
        #expect(new != original)
        #expect(try await resolver.identity(for: tree.file) == new)
        #expect(try await resolver.identity(for: renamed) == original)
    }
}

@Test func itemResolverFileGrantsUseResourceBytesWhenAvailable() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let first = FileItemIdentityResolver()
    let item = try await first.identity(for: tree.file)
    #expect(item.stableEncoding.hasPrefix("id1:res:"))
    #expect(try await FileItemIdentityResolver().identity(for: tree.file) == item)
    let renamed = tree.root.appendingPathComponent("renamed.png")
    try FileManager.default.moveItem(at: tree.file, to: renamed)
    #expect(try await first.identity(for: renamed) == item)
    #expect(try await FileItemIdentityResolver().identity(for: renamed) == item)
}

@Test func issue140MovedRootKeepsRenamedItemIdentity() async throws {
    let tree = try IdentityTree()
    let movedRoot = tree.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: tree.root)
        try? FileManager.default.removeItem(at: movedRoot)
    }
    let registry = RootIdentityResolvers()
    let before = await registry.resolver(for: tree.scope)
    let original = try await before.identity(for: tree.file)
    let renamed = tree.root.appendingPathComponent("renamed.png")
    try FileManager.default.moveItem(at: tree.file, to: renamed)
    #expect(try await before.identity(for: renamed) == original)

    try FileManager.default.moveItem(at: tree.root, to: movedRoot)
    let moved = await registry.resolver(for: ItemIdentityRoot(id: tree.id, url: movedRoot))
    let movedRenamed = movedRoot.appendingPathComponent("renamed.png")
    #expect(try await moved.identity(for: movedRenamed) == original)
    let movedOriginal = movedRoot.appendingPathComponent("b.png")
    try FileManager.default.moveItem(at: movedRenamed, to: movedOriginal)
    #expect(try await moved.identity(for: movedOriginal) == original)
}

@Test func issue140MovedRootDoesNotBorrowAnotherRootIdentity() async throws {
    let first = try IdentityTree(), second = try IdentityTree()
    let movedFirst = first.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: first.root)
        try? FileManager.default.removeItem(at: movedFirst)
        second.remove()
    }
    let registry = RootIdentityResolvers()
    let firstResolver = await registry.resolver(for: first.scope)
    let secondResolver = await registry.resolver(for: ItemIdentityRoot(id: AccessRootID(), url: second.root))
    let firstID = try await firstResolver.identity(for: first.file)
    let secondID = try await secondResolver.identity(for: second.file)
    #expect(firstID != secondID)
    try FileManager.default.moveItem(at: first.root, to: movedFirst)
    let movedResolver = await registry.resolver(for: ItemIdentityRoot(id: first.id, url: movedFirst))
    #expect(try await movedResolver.identity(for: movedFirst.appendingPathComponent("b.png")) == firstID)
    #expect(try await secondResolver.identity(for: second.file) == secondID)
}

@Test func issue140MovedRootKeepsAssociationWhenOldNameIsReused() async throws {
    let tree = try IdentityTree()
    let movedRoot = tree.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: tree.root)
        try? FileManager.default.removeItem(at: movedRoot)
    }
    let registry = RootIdentityResolvers()
    let initial = await registry.resolver(for: tree.scope)
    let original = try await initial.identity(for: tree.file)
    let renamed = tree.root.appendingPathComponent("renamed.png")
    try FileManager.default.moveItem(at: tree.file, to: renamed)
    #expect(try await initial.identity(for: renamed) == original)
    try FileManager.default.moveItem(at: tree.root, to: movedRoot)
    try FileManager.default.createDirectory(at: tree.root, withIntermediateDirectories: false)
    let moved = await registry.resolver(for: ItemIdentityRoot(id: tree.id, url: movedRoot))
    #expect(try await moved.identity(for: movedRoot.appendingPathComponent("renamed.png")) == original)
}

private struct ReusedResourceReader: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        FileResourceIdentity(volumeUUID: "fixture", fileIdentifier: "reused")
    }
}

@Test func issue140CompletedScanPrunesDeletedResourceAssociation() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let resolver = FileItemIdentityResolver(root: tree.scope, reader: ReusedResourceReader())
    let deletedID = try await resolver.identity(for: tree.file)
    try FileManager.default.removeItem(at: tree.file)
    await resolver.pruneMissing(in: tree.root, recursive: false)
    let replacement = tree.root.appendingPathComponent("new.png")
    try Data("different".utf8).write(to: replacement)
    #expect(try await resolver.identity(for: replacement) != deletedID)
}

@Test func issue140IndexedResolverKeepsThousandsOfRealFilesDistinctAcrossRescan() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let resolver = FileItemIdentityResolver(root: tree.scope)
    let count = 2_500
    var files: [URL] = []
    files.reserveCapacity(count)
    for index in 0..<count {
        let file = tree.root.appendingPathComponent(String(format: "bulk-%04d.png", index))
        try Data().write(to: file)
        files.append(file)
    }
    var first: [ItemID] = []
    first.reserveCapacity(count)
    for file in files { first.append(try await resolver.identity(for: file)) }
    #expect(Set(first).count == count)
    for (index, file) in files.enumerated() {
        #expect(try await resolver.identity(for: file) == first[index])
    }
}
