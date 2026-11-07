import Foundation
import Darwin
import Testing
import MadoCore
@testable import MadoInfrastructure

private actor T231MountedVolumes: DiskMountPort {
    let volume: AccessProbeVolume
    init(_ volume: AccessProbeVolume) { self.volume = volume }
    func mountedVolumes() -> [AccessProbeVolume] { [volume] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}

private struct T231NoRecoveryIdentity: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { nil }
}

@Test(.timeLimit(.minutes(2)))
func t231LegacyRootWithoutRecoveryIdentityStillRequiresOriginalIdentity() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(), codec = FakeBookmarks()
    let original = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T231-legacy")
    let id = try await original.grant(folder: f.old)
    let volume = AccessProbeVolume(uuid: "legacy-volume", url: nil, name: "Legacy")
    let restored = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T231-legacy-launch",
        recoveryResourceReader: T231NoRecoveryIdentity(), requiresEmbeddedIdentity: true,
        bookmarkVolume: { _ in volume }, resolvedVolumeUUID: { _ in "legacy-volume" },
        bookmarkIdentity: { _ in nil }, mountedVolumesProvider: { [volume] })
    let lease = try await restored.acquire(.root(id, file: f.old))
    #expect(lease.rootID == id && lease.url == f.old)
    // Retain the original inode under a different name, so recreating the old
    // path cannot coincidentally reuse it and defeat the identity regression.
    try FileManager.default.moveItem(at: f.old, to: f.base.appendingPathComponent("retained-original"))
    try FileManager.default.createDirectory(at: f.old, withIntermediateDirectories: true)
    await #expect(throws: FileAccessError.needsReconnection(id)) {
        try await restored.acquire(.root(id, file: f.old))
    }
    #expect(await restored.rootURL(id) == nil)
    await restored.release(lease)
    #expect(scope.balanced)
}

/// A legacy root (no embedded or recovery identity) whose live identity still matches the launch baseline stays
/// readable across repeated admissions, both fresh and joining a live session. Coverage context (#281, ACCESS-03):
/// the success return of `validateLegacyRoot` is a derived coverage region, so it is exercised many times here
/// rather than once, which parallel runs could lose.
@Test(.timeLimit(.minutes(2)))
func t231MatchingLegacyRootStaysReadableAcrossRepeatedAdmissions() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(), codec = FakeBookmarks()
    let original = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T231-legacy-match")
    let id = try await original.grant(folder: f.old)
    let volume = AccessProbeVolume(uuid: "legacy-volume", url: nil, name: "Legacy")
    let restored = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "T231-legacy-match-launch",
        recoveryResourceReader: T231NoRecoveryIdentity(), requiresEmbeddedIdentity: true,
        bookmarkVolume: { _ in volume }, resolvedVolumeUUID: { _ in "legacy-volume" },
        bookmarkIdentity: { _ in nil }, mountedVolumesProvider: { [volume] })
    for round in 0..<64 {
        // A fresh session, then a second lease joining it while it is live.
        let first = try await restored.acquire(.root(id, file: f.old))
        let joined = try await restored.acquire(.root(id, file: f.old))
        #expect(first.rootID == id && first.url == f.old, "round \(round): fresh lease")
        #expect(joined.rootID == id && joined.url == f.old, "round \(round): joined lease")
        #expect(await restored.rootURL(id) == f.old, "round \(round): root kept")
        await restored.release(joined)
        await restored.release(first)
    }
    #expect(await restored.records().map(\.id) == [id])
    #expect(await restored.rootURL(id) == f.old)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231AutomaticTrashRootAdmissionNeverPublishesReadable(_ held: Bool) async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(), system = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: system, store: f.store, buildSHA: "T231")
    let id = try await access.grant(folder: f.old)
    // Foundation preserves /var here while a real bookmark uses /private/var.
    // Capture the physical fixture location while it exists, before Trash.
    let physicalPath = try #require(f.old.path.withCString { realpath($0, nil) })
    defer { free(physicalPath) }
    let expectedRoot = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
    let oldLease = held ? try await access.acquire(.root(id, file: f.old)) : nil
    let saved = try #require(await access.records().first).bookmark
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: saved)
    var trashed: NSURL?
    try FileManager.default.trashItem(at: f.old, resultingItemURL: &trashed)
    defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }
    let trash = try #require(trashed as URL?)
    #expect(FileAccess.isTrashed(trash))
    #expect(try system.resolve(saved).url.resolvingSymlinksInPath() == trash.resolvingSymlinksInPath())
    // All automatic entrances must reject even a valid, resolvable bookmark.
    await #expect(throws: FileAccessError.needsReconnection(id)) {
        try await access.acquire(.root(id, file: trash))
    }
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await access.probeRootURL(id) }
    #expect(await access.rootURL(id) == nil)
    let result = await access.verifySavedRootForRecovery(id, mounts: T231MountedVolumes(volume))
    #expect(result.classification == AccessProbeClassification(cause: .notFound, isInTrash: true))
    #expect(result.rootURL == nil && result.folderURL == nil)
    let launch = try FileAccess(scope: scope, bookmarks: system, store: f.store, buildSHA: "T231-relaunch")
    #expect(await launch.rootURL(id) == nil)
    #expect(await launch.launchOutcomes()[id] == "failed")
    await #expect(throws: FileAccessError.needsReconnection(id)) { try await launch.probeRootURL(id) }
    #expect(try f.store.load().first?.bookmark == saved)
    if let oldLease {
        #expect(oldLease.url.resolvingSymlinksInPath().path == expectedRoot.resolvingSymlinksInPath().path)
        await access.release(oldLease)
        await access.release(oldLease)
    }
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)))
func t231RealBookmarkMissingRenameAndPlainTrash() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let scope = ReconnectScope(), system = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: system, store: f.store, buildSHA: "T231")
    let id = try await access.grant(folder: f.old)
    let moved = f.base.appendingPathComponent(".Trash/photos")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: f.old, to: moved)
    #expect(!FileAccess.isTrashed(moved))
    let lease = try await access.acquire(.root(id, file: moved))
    #expect(lease.rootID == id && lease.url.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
    await access.release(lease)
    let saved = try #require(await access.records().first).bookmark
    try FileManager.default.removeItem(at: moved)
    let volume = AccessProbeFactGatherer.bookmarkVolume(in: saved)
    let result = await access.verifySavedRootForRecovery(id, mounts: T231MountedVolumes(volume))
    #expect(result.classification.cause == .notFound)
    #expect(result.rootURL == nil && result.folderURL == nil)
    #expect(scope.balanced)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func t231TrashClassificationDoesNotDependOnResolution(_ failed: Bool) {
    let volume = AccessProbeVolume(uuid: nil, url: nil, name: nil)
    let result = AccessCauseClassifier.classify(AccessProbeFacts(volume: volume, mountedVolumes: [],
        resolution: failed ? .failed(domain: NSCocoaErrorDomain, code: 259)
            : .resolved(URL(fileURLWithPath: "/somewhere"), stale: false),
        scopeStarted: nil, listing: nil, isInTrash: true))
    #expect(result == AccessProbeClassification(cause: .notFound, isInTrash: true))
}

@Test(.timeLimit(.minutes(2)))
func t231TrashDescendantNeverUsesReadableAncestorAuthority() async throws {
    let f = try ReconnectFixture(); defer { f.remove() }
    let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
        appropriateFor: f.base, create: false)
    let ancestor = trash.deletingLastPathComponent()
    let scope = ReconnectScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: f.store, buildSHA: "T231-descendant")
    let id = try await access.grant(folder: ancestor)
    // No home content is enumerated: only admission of this known Trash path is tested.
    await #expect(throws: FileAccessError.outsideRoot) {
        try await access.acquire(.root(id, file: trash.appendingPathComponent("unopened.png")))
    }
    #expect(await access.rootURL(id) == ancestor)
    let lease = try await access.acquire(.root(id, file: ancestor))
    #expect(lease.rootID == id && lease.url == ancestor)
    await access.release(lease)
    #expect(scope.balanced)
}
