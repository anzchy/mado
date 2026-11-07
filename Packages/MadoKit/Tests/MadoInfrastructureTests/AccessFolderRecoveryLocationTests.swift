// WI5 scoped folder identity and location regression tests.
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private struct T229RecoveryLocationFixture {
    let base: URL
    let root: URL
    let child: URL
    let scope: CountingScope
    let bookmarks: FakeBookmarks
    let files: FileAccess
    init(resourceReader: any FileIdentityResourceReading = URLIdentityResourceReader()) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Photos", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let scope = CountingScope(), bookmarks = FakeBookmarks()
        self.base = base; self.root = root; self.child = child
        self.scope = scope; self.bookmarks = bookmarks
        files = try FileAccess(scope: scope, bookmarks: bookmarks,
            store: BookmarkStore(url: base.appendingPathComponent("support/roots.json")), buildSHA: "T229-WI5",
            resourceReader: resourceReader)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL }
}

@Test func t229RecoveryLocationCapturesScopedIdentityAndVersionedResult() async throws {
    let f = try T229RecoveryLocationFixture(); defer { f.remove() }
    let id = try await f.files.grant(folder: f.root)
    let reference = try #require(try await f.files.captureRecoveryFolder(rootID: id, folder: f.child))
    #expect(reference.rootID == id)
    #expect(reference.relativeComponents == ["child"])
    #expect(reference.folderURL == f.canonical(f.child))
    #expect(reference.rootIdentity == (try URLIdentityResourceReader().identity(for: f.root)))
    #expect(reference.folderIdentity == (try URLIdentityResourceReader().identity(for: f.child)))
    let resolved = try #require(try await f.files.resolveRecoveryFolder(reference, verifiedRoot: f.root))
    #expect(resolved.rootURL == f.canonical(f.root))
    #expect(resolved.folderURL == f.canonical(f.child))
    #expect(try resolved.grant.admitting { resolved.grant.record.id } == id)
    _ = try await f.files.grant(folder: f.root)
    #expect(throws: CancellationError.self) { try resolved.grant.admitting {} }
    #expect(f.scope.counts[0] == f.scope.counts[1])
}

@Test func t229RecoveryLocationMissingOrReplacedChildFallsBackToRoot() async throws {
    for replaces in [false, true] {
        let f = try T229RecoveryLocationFixture(); defer { f.remove() }
        let id = try await f.files.grant(folder: f.root)
        let reference = try #require(try await f.files.captureRecoveryFolder(rootID: id, folder: f.child))
        if replaces {
            // Keep the old inode alive so same-path replacement cannot reuse it.
            try FileManager.default.moveItem(at: f.child, to: f.base.appendingPathComponent("original-child"))
            try FileManager.default.createDirectory(at: f.child, withIntermediateDirectories: true)
        } else { try FileManager.default.removeItem(at: f.child) }
        #expect(try await f.files.resolveRecoveryFolder(reference, verifiedRoot: f.root) == nil)
        #expect(await f.files.rootURL(id) == f.root)
        #expect(f.scope.counts[0] == f.scope.counts[1])
    }
}

@Test func t229RecoveryLocationDoesNotFollowOriginalFolderOutsideRoot() async throws {
    let f = try T229RecoveryLocationFixture(); defer { f.remove() }
    let id = try await f.files.grant(folder: f.root)
    let reference = try #require(try await f.files.captureRecoveryFolder(rootID: id, folder: f.child))
    let outside = f.base.appendingPathComponent("outside")
    // The symlink reaches the original inode, so identity alone cannot reject it.
    try FileManager.default.moveItem(at: f.child, to: outside)
    try FileManager.default.createSymbolicLink(at: f.child, withDestinationURL: outside)
    #expect(try await f.files.resolveRecoveryFolder(reference, verifiedRoot: f.root) == nil)
    #expect(f.scope.counts[0] == f.scope.counts[1])
}

@Test func t229RecoveryLocationRebasesActualFolderAfterRootPathChanges() async throws {
    let f = try T229RecoveryLocationFixture(); defer { f.remove() }
    let id = try await f.files.grant(folder: f.root)
    let reference = try #require(try await f.files.captureRecoveryFolder(rootID: id, folder: f.child))
    let relocated = f.base.appendingPathComponent("RemountedPhotos")
    try FileManager.default.moveItem(at: f.root, to: relocated)
    f.bookmarks.relocated = relocated
    let resolved = try #require(try await f.files.resolveRecoveryFolder(reference, verifiedRoot: relocated))
    #expect(resolved.rootURL == f.canonical(relocated))
    #expect(resolved.folderURL == f.canonical(relocated.appendingPathComponent("child")))
    #expect(try URLIdentityResourceReader().identity(for: resolved.folderURL) == reference.folderIdentity)
    #expect(f.scope.counts[0] == f.scope.counts[1])
}

@Test func t229RecoveryLocationRejectsReplacedRootEvenIfChildInodeSurvives() async throws {
    let f = try T229RecoveryLocationFixture(); defer { f.remove() }
    let id = try await f.files.grant(folder: f.root)
    let reference = try #require(try await f.files.captureRecoveryFolder(rootID: id, folder: f.child))
    let original = f.base.appendingPathComponent("original-root")
    try FileManager.default.moveItem(at: f.root, to: original)
    try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: original.appendingPathComponent("child"), to: f.child)
    await #expect(throws: FileAccessError.needsReconnection(id)) {
        try await f.files.resolveRecoveryFolder(reference, verifiedRoot: f.root)
    }
    #expect(f.scope.counts[0] == f.scope.counts[1])
}

@Test func t229RecoveryLocationRootFailureIsNotChildFallback() async throws {
    for scopeFailure in [false, true] {
        let f = try T229RecoveryLocationFixture(); defer { f.remove() }
        let id = try await f.files.grant(folder: f.root)
        let reference = try #require(try await f.files.captureRecoveryFolder(rootID: id, folder: f.child))
        if scopeFailure { f.scope.succeeds = false }
        else { f.bookmarks.fails = true }
        await #expect(throws: scopeFailure ? FileAccessError.startFailed : .needsReconnection(id)) {
            try await f.files.resolveRecoveryFolder(reference, verifiedRoot: f.root)
        }
        #expect(f.scope.counts[0] == f.scope.counts[1] + (scopeFailure ? 1 : 0))
    }
}

private struct T229NoRecoveryIdentity: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { nil }
}

@Test func t229RecoveryCaptureWithoutIdentityOrAuthorityNeverInventsReference() async throws {
    let noIdentity = try T229RecoveryLocationFixture(resourceReader: T229NoRecoveryIdentity())
    defer { noIdentity.remove() }
    let id = try await noIdentity.files.grant(folder: noIdentity.root)
    #expect(try await noIdentity.files.captureRecoveryFolder(rootID: id, folder: noIdentity.child) == nil)
    #expect(noIdentity.scope.counts[0] == noIdentity.scope.counts[1])
    let f = try T229RecoveryLocationFixture(); defer { f.remove() }
    let rootID = try await f.files.grant(folder: f.root)
    let outside = f.base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    await #expect(throws: FileAccessError.outsideRoot) {
        try await f.files.captureRecoveryFolder(rootID: rootID, folder: outside)
    }
    #expect(f.scope.counts[0] == f.scope.counts[1])
}
