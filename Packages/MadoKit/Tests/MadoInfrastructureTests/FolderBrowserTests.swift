import Foundation
import Testing
import MadoCore
import MadoInfrastructure

private actor FolderBrowserBatches {
    var batches: [[FolderEntry]] = []
    func append(_ entries: [FolderEntry]) { batches.append(entries) }
}

private struct FolderBrowserTree {
    let tree: URL
    let folder: URL
    let root: ItemIdentityRoot
    init(count: Int = 0) throws {
        tree = FileManager.default.temporaryDirectory.appendingPathComponent("folder-browser-\(UUID().uuidString)")
        folder = tree.appendingPathComponent("root")
        root = ItemIdentityRoot(id: AccessRootID(), url: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data().write(to: folder.appendingPathComponent(String(format: "img%04d.png", index)))
        }
    }
    func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: tree) }
}

@Test(.timeLimit(.minutes(2))) func folderBrowserMembershipMatchesSiblingLister() async throws {
    let fixture = try FolderBrowserTree()
    defer { fixture.remove() }
    let manager = FileManager.default
    let image = try fixture.file("a.png")
    _ = try fixture.file("b.TIFF")
    _ = try fixture.file("c.JpG")
    _ = try fixture.file(".hidden.png")
    _ = try fixture.file("notes.txt")
    for directory in ["sub", "package.app"] {
        let url = fixture.folder.appendingPathComponent(directory)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        try Data().write(to: url.appendingPathComponent("nested.png"))
    }
    try manager.createSymbolicLink(at: fixture.folder.appendingPathComponent("inside.png"), withDestinationURL: image)
    let outside = fixture.tree.appendingPathComponent("outside.png")
    try Data().write(to: outside)
    try manager.createSymbolicLink(at: fixture.folder.appendingPathComponent("outside.png"), withDestinationURL: outside)
    let collected = FolderBrowserBatches()
    try await FolderBrowser().scan(in: fixture.folder, root: fixture.root) { await collected.append($0) }
    let entries = await collected.batches.flatMap { $0 }
    let expected: Set<String> = ["a.png", "b.TIFF", "c.JpG", "inside.png"]
    #expect(Set(entries.map { $0.url.lastPathComponent }) == expected)
    let old = try await SiblingLister().images(in: fixture.folder, root: fixture.folder)
    #expect(Set(entries.map(\.url)) == Set(old))
    let resolver = FileItemIdentityResolver(root: fixture.root)
    for entry in entries {
        #expect(entry.itemID == (try await resolver.identity(for: entry.url)))
    }
    let alias = try #require(entries.first { $0.url.lastPathComponent == "inside.png" })
    #expect(alias.itemID == ItemID.rootRelative(rootID: fixture.root.id, relativePath: "a.png"))
}

@Test(.timeLimit(.minutes(2)), arguments: [0, 1, 63, 64, 65, 321])
func folderBrowserBatchBoundaries(count: Int) async throws {
    let fixture = try FolderBrowserTree(count: count)
    defer { fixture.remove() }
    let collected = FolderBrowserBatches()
    try await FolderBrowser().scan(in: fixture.folder, root: fixture.root) { await collected.append($0) }
    let batches = await collected.batches
    let expectedSizes: [Int]
    switch count {
    case 0: expectedSizes = []
    case 1: expectedSizes = [1]
    case 63: expectedSizes = [63]
    case 64: expectedSizes = [64]
    case 65: expectedSizes = [64, 1]
    default: expectedSizes = [64, 256, 1]
    }
    #expect(FolderBrowser.firstBatchSize == 64)
    #expect(FolderBrowser.batchSize == 256)
    #expect(batches.map(\.count) == expectedSizes)
    let names = batches.flatMap { $0 }.map { $0.url.lastPathComponent }
    let expected = Set((0..<count).map { String(format: "img%04d.png", $0) })
    #expect(Set(names) == expected)
    #expect(names.count == count)
}

@Test(.timeLimit(.minutes(2))) func folderBrowserConsumerCancellation() async throws {
    let fixture = try FolderBrowserTree(count: 321)
    defer { fixture.remove() }
    let collected = FolderBrowserBatches()
    let task = Task {
        try await FolderBrowser().scan(in: fixture.folder, root: fixture.root) { batch in
            await collected.append(batch)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    var cancelled = false
    do { try await task.value } catch is CancellationError { cancelled = true }
    #expect(cancelled)
    let batches = await collected.batches
    #expect(batches.map(\.count) == [64])
}

@Test(.timeLimit(.minutes(2))) func folderBrowserOutsideRootAndMissingFolder() async throws {
    let fixture = try FolderBrowserTree()
    defer { fixture.remove() }
    let collected = FolderBrowserBatches()
    var outsideError: FileAccessError?
    do {
        try await FolderBrowser().scan(in: fixture.tree, root: fixture.root) { await collected.append($0) }
    } catch { outsideError = error as? FileAccessError }
    #expect(outsideError == .outsideRoot)
    var missingError: NSError?
    do {
        try await FolderBrowser().scan(in: fixture.folder.appendingPathComponent("missing"), root: fixture.root) {
            await collected.append($0)
        }
    } catch { missingError = error as NSError }
    #expect(missingError?.domain == NSCocoaErrorDomain)
    #expect(missingError?.code == NSFileReadNoSuchFileError)
    #expect(await collected.batches.isEmpty)
}

private struct FolderBrowserDeliveryError: Error {}
@Test(.timeLimit(.minutes(2))) func folderBrowserDeliveryFailureStopsEnumeration() async throws {
    let fixture = try FolderBrowserTree(count: 321)
    defer { fixture.remove() }
    let collected = FolderBrowserBatches()
    var failed = false
    do {
        try await FolderBrowser().scan(in: fixture.folder, root: fixture.root) {
            await collected.append($0)
            throw FolderBrowserDeliveryError()
        }
    } catch is FolderBrowserDeliveryError { failed = true }
    #expect(failed)
    #expect(await collected.batches.map(\.count) == [64])
}

@Test(.timeLimit(.minutes(2))) func folderBrowserCollectsSortMetadata() async throws {
    let fixture = try FolderBrowserTree()
    defer { fixture.remove() }
    let file = fixture.folder.appendingPathComponent("metadata.JpG")
    try Data(repeating: 7, count: 37).write(to: file)
    let modified = Date(timeIntervalSince1970: 1_234_567)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    let collected = FolderBrowserBatches()
    try await FolderBrowser().scan(in: fixture.folder, root: fixture.root) { await collected.append($0) }
    let entry = try #require(await collected.batches.flatMap { $0 }.first)
    #expect(entry.fileSize == 37)
    #expect(entry.modificationDate == modified)
    #expect(entry.normalizedExtension == "jpg")
}
