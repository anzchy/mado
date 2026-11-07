import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private actor RecursiveResults {
    var entries: [FolderEntry] = []
    func append(_ batch: [FolderEntry]) { entries += batch }
}

private actor RecursiveRootLease: AccessLeasing {
    let root: URL
    init(root: URL) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease { AccessLease(url: root, rootID: nil) }
    func release(_ lease: AccessLease) { }
}

private final class FailingMetadataRead: @unchecked Sendable {
    private let lock = NSLock()
    private let failAfterImages: Int
    private var images = 0
    init(failAfterImages: Int) { self.failAfterImages = failAfterImages }
    func read(_ url: URL) throws -> URLResourceValues {
        lock.lock()
        defer { lock.unlock() }
        if url.pathExtension == "png" {
            if images == failAfterImages { throw CocoaError(.fileReadUnknown) }
            images += 1
        }
        return try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey,
            .contentTypeKey, .contentModificationDateKey, .fileSizeKey])
    }
}

private final class DepthGuardMetadataRead: @unchecked Sendable {
    private let lock = NSLock()
    private let image: URL
    private let directory: URL
    private var calls = 0
    init(image: URL, directory: URL) { self.image = image; self.directory = directory }
    func read(_ url: URL) throws -> URLResourceValues {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let source = calls == 1 ? image : directory
        return try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey,
            .contentTypeKey, .contentModificationDateKey, .fileSizeKey])
    }
}

private struct RecursiveTree {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("mado-recursive-\(UUID())")
    let rootID = AccessRootID()
    var root: URL { base.appendingPathComponent("root") }
    var identity: ItemIdentityRoot { .init(id: rootID, url: root) }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func image(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try Data().write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Test func recursiveScanIncludesNestedImagesOnlyWhenEnabled() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.image("top.png")
    _ = try tree.directory("sub")
    _ = try tree.image("sub/nested.png")
    let off = RecursiveResults(), on = RecursiveResults()
    let root = tree.identity
    try await FolderBrowser().scan(in: tree.root, root: root) { await off.append($0) }
    try await FolderBrowser().scan(in: tree.root, root: root, options: .init(recursive: true)) { await on.append($0) }
    #expect(Set(await off.entries.map(\.relativePath)) == ["top.png"])
    #expect(Set(await on.entries.map(\.relativePath)) == ["top.png", "sub/nested.png"])
}

@Test func p204R3FlatFolderBeyondRecursiveEntryLimitStillCompletes() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    let source = tree.root.appendingPathComponent("seed.txt")
    try Data().write(to: source)
    for index in 0..<100_000 {
        try FileManager.default.linkItem(at: source,
            to: tree.root.appendingPathComponent(String(format: "%06d.txt", index)))
    }
    let result = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity, options: .init(recursive: false)) {
        await result.append($0)
    }
    #expect(await result.entries.isEmpty)
}

@Test @MainActor func p204R3UnreadableSubdirectoryRetainsPartialFailureSurface() async throws {
    let tree = try RecursiveTree()
    let blocked = try tree.directory("blocked")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        tree.cleanup()
    }
    _ = try tree.image("top.png")
    _ = try tree.image("blocked/nested.png")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    #expect(!FileManager.default.isReadableFile(atPath: blocked.path))
    let coordinator = FolderScanCoordinator(access: RecursiveRootLease(root: tree.root), scanner: FolderBrowser())
    let session = ViewerSession()
    session.folderScan = coordinator
    _ = coordinator.setRecursiveEnabled(true)
    let task = coordinator.begin(folder: tree.root, rootID: tree.rootID)
    do { try await task.value } catch { }
    #expect(coordinator.failure != nil)
    #expect(coordinator.failureReason == "Folder access denied")
    // #238: a folder-entry failure keeps no partial source (24F-A shows no partial list or count).
    #expect(coordinator.sourceSnapshot == nil)
    #expect(session.imageStatus == .folderScanFailed("Folder access denied", tree.root.lastPathComponent))
}

@Test func recursiveScanRejectsOutsideLinksAndCyclesWithoutDuplicateIdentity() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    let sub = try tree.directory("sub")
    let image = try tree.image("sub/a.png")
    try FileManager.default.createSymbolicLink(at: sub.appendingPathComponent("back"), withDestinationURL: tree.root)
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("alias.png"), withDestinationURL: image)
    let outside = tree.base.appendingPathComponent("outside.png")
    try Data().write(to: outside)
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("outside.png"), withDestinationURL: outside)
    let outsideDirectory = tree.base.appendingPathComponent("outside-directory")
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try Data().write(to: outsideDirectory.appendingPathComponent("escaped.png"))
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("outside-directory"),
        withDestinationURL: outsideDirectory)
    let result = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity, options: .init(recursive: true)) { await result.append($0) }
    let entries = await result.entries
    #expect(entries.count == 2)
    #expect(Set(entries.map(\.itemID)) == [.rootRelative(rootID: tree.rootID, relativePath: "sub/a.png")])
}

@Test func p204FixAliasFilterKeepsEligibleNestedRepresentative() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.image("a.png")
    _ = try tree.directory("sub")
    let nested = try tree.image("sub/b.png")
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("link.jpg"), withDestinationURL: nested)
    let result = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity, options: .init(recursive: true)) {
        await result.append($0)
    }
    let entries = await result.entries
    let snapshot = FolderSnapshot(version: .init(rootID: tree.rootID, folder: tree.root, generation: 1),
        entries: entries, isComplete: true)
    #expect(Set(entries.map(\.relativePath)) == ["a.png", "link.jpg", "sub/b.png"])
    #expect(snapshot.navigationEntries.count == 2)
    let png = snapshot.applying(.init(selectedExtensions: ["png"]))
    #expect(png.navigationEntries.map(\.relativePath) == ["a.png", "sub/b.png"])
    #expect(png.navigationEntries.count == 2)
    #expect(snapshot.applying(.init(sort: .type, direction: .descending)).navigationEntries.count == 2)
}

@Test(arguments: ["00-link.jpg", "z-link.jpg"])
func recursiveAliasNameDoesNotChangeFilteredSort(aliasName: String) async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.image("a.png")
    _ = try tree.directory("sub")
    let nested = try tree.image("sub/b.png")
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent(aliasName), withDestinationURL: nested)
    let result = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity, options: .init(recursive: true)) {
        await result.append($0)
    }
    let snapshot = FolderSnapshot(version: .init(rootID: tree.rootID, folder: tree.root, generation: 1),
        entries: await result.entries, isComplete: true)
    #expect(snapshot.navigationEntries.count == 2)
    let filtered = snapshot.applying(.init(sort: .name, direction: .descending, selectedExtensions: ["png"]))
    #expect(filtered.navigationEntries.map(\.relativePath) == ["sub/b.png", "a.png"])
    #expect(Set(filtered.navigationEntries.map(\.itemID)).count == 2)
}

@Test(arguments: [3, 70]) func p204FixMetadataFailureEmitsBufferedPrefix(imageCount: Int) async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    for index in 0...imageCount { _ = try tree.image(String(format: "%04d.png", index)) }
    let failure = FailingMetadataRead(failAfterImages: imageCount)
    let result = RecursiveResults()
    var didFail = false
    do {
        try await FolderBrowser(readValues: failure.read).scan(in: tree.root, root: tree.identity,
            options: .init(recursive: true)) { await result.append($0) }
    } catch { didFail = (error as NSError).domain == NSCocoaErrorDomain }
    #expect(didFail)
    let entries = await result.entries
    #expect(entries.count == imageCount)
    #expect(Set(entries.map(\.itemID)).count == imageCount)
}

@Test @MainActor func recursiveAliasCountTracksUniqueNavigationAcrossModesAndFilter() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.image("a.png")
    _ = try tree.directory("sub")
    let nested = try tree.image("sub/b.png")
    try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("link.jpg"), withDestinationURL: nested)
    let coordinator = FolderScanCoordinator(access: RecursiveRootLease(root: tree.root), scanner: FolderBrowser())
    try await coordinator.begin(folder: tree.root, rootID: tree.rootID).value
    #expect(coordinator.sourceSnapshot?.entries.count == 2)
    #expect(coordinator.completedImageCount == 2)
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(coordinator.snapshot?.navigationEntries.map(\.relativePath) == ["a.png"])
    let recursive = try #require(coordinator.setRecursiveEnabled(true))
    try await recursive.value
    #expect(coordinator.sourceSnapshot?.entries.count == 3)
    #expect(coordinator.completedImageCount == 2)
    #expect(coordinator.snapshot?.navigationEntries.map(\.relativePath) == ["a.png", "sub/b.png"])
}

@Test @MainActor func recursiveBufferedFailureCountMatchesRetainedSnapshot() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    for index in 0...3 { _ = try tree.image(String(format: "%04d.png", index)) }
    let failure = FailingMetadataRead(failAfterImages: 3)
    let coordinator = FolderScanCoordinator(access: RecursiveRootLease(root: tree.root),
        scanner: FolderBrowser(readValues: failure.read))
    _ = try? await coordinator.begin(folder: tree.root, rootID: tree.rootID).value
    #expect(coordinator.failure != nil)
    // #238: a folder-entry failure keeps no partial source, so no buffered count survives it.
    #expect(coordinator.sourceSnapshot == nil)
    #expect(coordinator.failureReason == "Folder scan failed")
    #expect(coordinator.completedImageCount == nil)
}

@Test func recursiveDepthGuardFlushesPendingImageBeforeFailure() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    let image = try tree.image("a.png")
    _ = try tree.image("b.png")
    let directory = try tree.directory("metadata-directory")
    let values = DepthGuardMetadataRead(image: image, directory: directory)
    let result = RecursiveResults()
    var limitError: FolderScanLimitError?
    do {
        try await FolderBrowser(readValues: values.read).scan(in: tree.root, root: tree.identity,
            options: .init(recursive: true, maxDepth: 0)) { await result.append($0) }
    } catch { limitError = error as? FolderScanLimitError }
    #expect(limitError == .depthLimit(limit: 0, admittedImages: 1))
    #expect(await result.entries.count == 1)
}

@Test func recursiveScanEntryGuardReportsHonestPartialCount() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.image("a.png")
    _ = try tree.image("b.png")
    let result = RecursiveResults()
    var limitError: FolderScanLimitError?
    do {
        try await FolderBrowser().scan(in: tree.root, root: tree.identity,
            options: .init(recursive: true, maxVisitedEntries: 1)) { await result.append($0) }
    } catch { limitError = error as? FolderScanLimitError }
    #expect(limitError == .entryLimit(limit: 1, admittedImages: 1))
    #expect(await result.entries.count == 1)
}

@Test func recursiveScanGuardBoundaryAndDepthAreExplicit() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.directory("sub")
    _ = try tree.image("sub/a.png")
    let exact = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity,
        options: .init(recursive: true, maxVisitedEntries: 2, maxDepth: 1)) { await exact.append($0) }
    #expect(await exact.entries.map(\.relativePath) == ["sub/a.png"])
    let limited = RecursiveResults()
    var limitError: FolderScanLimitError?
    do {
        try await FolderBrowser().scan(in: tree.root, root: tree.identity,
            options: .init(recursive: true, maxDepth: 0)) { await limited.append($0) }
    } catch { limitError = error as? FolderScanLimitError }
    #expect(limitError == .depthLimit(limit: 0, admittedImages: 0))
    #expect(await limited.entries.isEmpty)
}

@Test func recursiveScanEmptyAndHiddenPackageFoldersStayExcluded() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.directory("empty")
    _ = try tree.directory(".hidden")
    _ = try tree.image(".hidden/a.png")
    _ = try tree.directory("bundle.app")
    _ = try tree.image("bundle.app/a.png")
    let result = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity, options: .init(recursive: true)) {
        await result.append($0)
    }
    #expect(await result.entries.isEmpty)
}

@Test func recursiveScanDeepTreeStopsAtConfiguredDepth() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    var path = ""
    for level in 0..<8 {
        path += "d\(level)/"
        _ = try tree.directory(path)
    }
    _ = try tree.image(path + "deep.png")
    let result = RecursiveResults()
    var limitError: FolderScanLimitError?
    do {
        try await FolderBrowser().scan(in: tree.root, root: tree.identity,
            options: .init(recursive: true, maxDepth: 5)) { await result.append($0) }
    } catch { limitError = error as? FolderScanLimitError }
    #expect(limitError == .depthLimit(limit: 5, admittedImages: 0))
    #expect(await result.entries.isEmpty)
}

@Test func recursiveScanDeepAliasToSeenDirectoryDoesNotTripDepthGuard() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    let seen = try tree.directory("seen")
    _ = try tree.image("seen/a.png")
    let nested = try tree.directory("nested")
    try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("alias-to-seen"),
        withDestinationURL: seen)
    let result = RecursiveResults()
    try await FolderBrowser().scan(in: tree.root, root: tree.identity,
        options: .init(recursive: true, maxDepth: 1)) { await result.append($0) }
    #expect(await result.entries.count == 1)
}

@Test func recursiveScanCancellationStopsBeforeNextNestedBatch() async throws {
    let tree = try RecursiveTree(); defer { tree.cleanup() }
    _ = try tree.directory("sub")
    for index in 0..<321 { _ = try tree.image(String(format: "sub/%04d.png", index)) }
    let result = RecursiveResults()
    let task = Task {
        try await FolderBrowser().scan(in: tree.root, root: tree.identity, options: .init(recursive: true)) { batch in
            await result.append(batch)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    var cancelled = false
    do { try await task.value } catch is CancellationError { cancelled = true }
    #expect(cancelled)
    #expect(await result.entries.count == FolderBrowser.firstBatchSize)
}
