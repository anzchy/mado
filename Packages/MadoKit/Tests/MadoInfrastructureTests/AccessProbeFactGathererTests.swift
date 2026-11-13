import Foundation
import Testing
@testable import MadoInfrastructure

@Test func accessProbeGathererReadsRealBookmarkAndListsDirectory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let folder = root.appendingPathComponent("Photos", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("image".utf8).write(to: folder.appendingPathComponent("one.jpg"))

    let gatherer = AccessProbeFactGatherer()
    let plain = try gatherer.makeBookmark(for: folder, storingVolumeProperties: false)
    let enriched = try gatherer.makeBookmark(for: folder, storingVolumeProperties: true)
    let report = gatherer.gather(bookmarkData: enriched)
    let expectedUUID = try folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString

    #expect(plain != enriched)
    #expect(report.volume.uuid == expectedUUID)
    #expect(report.resolution.url?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    #expect(report.resolution.stale == false)
    #expect(report.scopeStarted != nil)
    #expect(report.listing?.entryCount == 1)
    #expect(report.listing?.error == nil)
    #expect(!report.isInTrash)
    #expect(report.classification.cause == .readable)
    #expect(report.latencyMilliseconds >= 0)
    #expect(report.latencies.volumePropertiesMilliseconds > 0)
    #expect(report.latencies.mountedVolumeScanMilliseconds > 0)
    #expect(report.latencies.resolutionMilliseconds > 0)
    #expect(report.latencies.scopeStartMilliseconds ?? 0 > 0)
    #expect(report.latencies.listingMilliseconds ?? 0 > 0)
}

private final class AccessProbeBookmarkRecorder: AccessProbeBookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOptions: URL.BookmarkResolutionOptions?
    var options: URL.BookmarkResolutionOptions? { lock.withLock { recordedOptions } }

    func makeBookmark(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?) throws -> Data {
        Data([1])
    }

    func volumeProperties(in data: Data) -> AccessProbeVolume {
        AccessProbeVolume(uuid: "volume-a", url: nil, name: "Photos")
    }

    func resolve(_ data: Data, options: URL.BookmarkResolutionOptions) throws -> AccessProbeResolution {
        lock.withLock { recordedOptions = options }
        return .resolved(URL(fileURLWithPath: "/Volumes/Photos/2026", isDirectory: true), stale: false)
    }
}

@Test func accessProbeResolutionNeverMountsOrShowsUI() {
    let bookmarks = AccessProbeBookmarkRecorder()
    let gatherer = AccessProbeFactGatherer(
        bookmarks: bookmarks,
        scope: SystemSecurityScope(),
        mountedVolumes: { [AccessProbeVolume(uuid: "volume-a", url: nil, name: "Photos")] },
        lister: { _ in 0 },
        isInTrash: { _ in false }
    )

    _ = gatherer.gather(bookmarkData: Data([1]))

    #expect(bookmarks.options == [.withSecurityScope, .withoutMounting, .withoutUI])
    // Retain observable output alongside the OS-resolution-options supplement.
    let observed = gatherer.gather(bookmarkData: Data([1]))
    #expect(observed.resolution.url == URL(fileURLWithPath: "/Volumes/Photos/2026", isDirectory: true))
    #expect(observed.listing?.entryCount == 0)
    #expect(observed.classification.cause == .readable)
}

@Test func accessProbeMountedVolumeScanHandlesMissingListAndProperties() {
    #expect(AccessProbeFactGatherer.mountedVolumes(at: nil) == [])

    let missing = URL(fileURLWithPath: "/Volumes/Missing-\(UUID().uuidString)", isDirectory: true)
    let volumes = AccessProbeFactGatherer.mountedVolumes(at: [missing])
    #expect(volumes.count == 1)
    #expect(volumes.first?.uuid == nil)
    #expect(volumes.first?.url == missing)
    #expect(volumes.first?.name == nil)
}

@Test func accessProbeGathererPreservesEveryUnderlyingError() throws {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    let middle = NSError(domain: "ProbeMiddle", code: 42, userInfo: [NSUnderlyingErrorKey: posix])
    let top = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
        NSUnderlyingErrorKey: middle,
    ])
    let gatherer = AccessProbeFactGatherer(
        bookmarks: AccessProbeBookmarkRecorder(),
        scope: SystemSecurityScope(),
        mountedVolumes: { [AccessProbeVolume(uuid: "volume-a", url: nil, name: "Photos")] },
        lister: { _ in throw top },
        isInTrash: { _ in false }
    )

    let report = gatherer.gather(bookmarkData: Data([1]))
    let error = try #require(report.listing?.error)

    #expect(error.domain == NSCocoaErrorDomain)
    #expect(error.code == NSFileReadNoPermissionError)
    #expect(error.underlyingErrors == [
        AccessProbeError(domain: "ProbeMiddle", code: 42),
        AccessProbeError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
    ])
    let json = try #require(String(data: JSONEncoder().encode(error), encoding: .utf8))
    #expect(json.contains("ProbeMiddle"))
    #expect(json.contains(NSPOSIXErrorDomain))
}

@Test func accessProbeGathererFollowsRenamedFolder() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let original = root.appendingPathComponent("Original", isDirectory: true)
    let renamed = root.appendingPathComponent("Renamed", isDirectory: true)
    try fileManager.createDirectory(at: original, withIntermediateDirectories: true)
    let gatherer = AccessProbeFactGatherer()
    let bookmark = try gatherer.makeBookmark(for: original, storingVolumeProperties: true)

    try fileManager.moveItem(at: original, to: renamed)
    let report = gatherer.gather(bookmarkData: bookmark)

    #expect(report.resolution.url?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
    #expect(report.resolution.stale == true)
    #expect(report.listing?.entryCount == 0)
    #expect(report.classification.cause == .readable)
}

@Test func accessProbeGathererCapturesDeletedFolderFailure() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let folder = root.appendingPathComponent("Deleted", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let gatherer = AccessProbeFactGatherer()
    let bookmark = try gatherer.makeBookmark(for: folder, storingVolumeProperties: true)

    try fileManager.removeItem(at: folder)
    let report = gatherer.gather(bookmarkData: bookmark)

    #expect(report.resolution.error != nil)
    #expect(report.classification.cause == .notFound)
}

#if MADO_TRASH_INTEGRATION
// #672: real DesktopServices Trash; runs only in `node scripts/tdd/trash-lane.mjs`.
@Test func accessProbeGathererMarksFolderInTrash() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var trashed: NSURL?
    defer {
        if let trashed { try? fileManager.removeItem(at: trashed as URL) }
        try? fileManager.removeItem(at: root)
    }
    let folder = root.appendingPathComponent("Trashed", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let gatherer = AccessProbeFactGatherer()
    let bookmark = try gatherer.makeBookmark(for: folder, storingVolumeProperties: true)

    try fileManager.trashItem(at: folder, resultingItemURL: &trashed)
    let report = gatherer.gather(bookmarkData: bookmark)

    #expect(report.resolution.url?.resolvingSymlinksInPath() == (trashed as URL?)?.resolvingSymlinksInPath())
    let resolvedURL = try #require(report.resolution.url)
    let trashInputs = try #require(report.trashCheckInputs)
    #expect(report.resolvedPath == resolvedURL.path)
    #expect(trashInputs.resolvedPath == resolvedURL.path)
    #expect(trashInputs.standardizedPath == resolvedURL.standardizedFileURL.path)
    #expect(trashInputs.userTrashPath != nil)
    #expect(trashInputs.volumePath != nil)
    #expect(trashInputs.perUserVolumeTrashPath != nil)
    #expect(report.isInTrash)
    #expect(report.classification.isInTrash)
    // #231: the signed T1 probe supports specific Not Found copy for Trash.
    #expect(report.classification.cause == .notFound)
}
#endif

/// #672 deterministic replacement: a renamed folder plus an injected Trash fact.
@Test func accessProbeGathererMarksFolderInTrashFromInjectedFact() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let folder = root.appendingPathComponent("Trashed", isDirectory: true)
    let trashed = root.appendingPathComponent("FactTrash/Trashed", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bookmarks = TrashFactProbeBookmarks(destination: trashed)
    let gatherer = AccessProbeFactGatherer(
        bookmarks: bookmarks,
        scope: SystemSecurityScope(),
        mountedVolumes: { [AccessProbeVolume(uuid: "volume-a", url: nil, name: "Fixture")] },
        lister: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).count },
        isInTrash: { $0.standardizedFileURL.path.hasPrefix(trashed.deletingLastPathComponent().standardizedFileURL.path + "/") }
    )
    let bookmark = try gatherer.makeBookmark(for: folder, storingVolumeProperties: true)

    try fileManager.moveItem(at: folder, to: trashed)
    let report = gatherer.gather(bookmarkData: bookmark)

    #expect(report.resolution.url?.resolvingSymlinksInPath() == trashed.resolvingSymlinksInPath())
    let resolvedURL = try #require(report.resolution.url)
    let trashInputs = try #require(report.trashCheckInputs)
    #expect(report.resolvedPath == resolvedURL.path)
    #expect(trashInputs.resolvedPath == resolvedURL.path)
    #expect(trashInputs.standardizedPath == resolvedURL.standardizedFileURL.path)
    #expect(trashInputs.userTrashPath != nil)
    #expect(trashInputs.volumePath != nil)
    #expect(trashInputs.perUserVolumeTrashPath != nil)
    #expect(report.isInTrash)
    #expect(report.classification.isInTrash)
    #expect(report.classification.cause == .notFound)
}

private struct TrashFactProbeBookmarks: AccessProbeBookmarkCoding {
    let destination: URL
    func makeBookmark(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: keys, relativeTo: nil)
    }
    func volumeProperties(in data: Data) throws -> AccessProbeVolume {
        AccessProbeVolume(uuid: "volume-a", url: nil, name: "Fixture")
    }
    func resolve(_ data: Data, options: URL.BookmarkResolutionOptions) throws -> AccessProbeResolution {
        .resolved(destination, stale: false)
    }
}

@Test func accessProbeGathererCapturesPermissionDenial() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let folder = root.appendingPathComponent("Denied", isDirectory: true)
    defer {
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? fileManager.removeItem(at: root)
    }
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let gatherer = AccessProbeFactGatherer()
    let bookmark = try gatherer.makeBookmark(for: folder, storingVolumeProperties: true)

    try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
    let report = gatherer.gather(bookmarkData: bookmark)

    #expect(report.scopeStarted != nil)
    #expect(report.listing?.error != nil)
    #expect(report.classification.cause == .accessExpired)
}

@Test func accessProbeGathererCapturesCorruptBookmarkError() {
    let report = AccessProbeFactGatherer().gather(bookmarkData: Data("corrupt".utf8))

    #expect(report.volume.uuid == nil)
    #expect(report.volumePropertiesError?.domain == NSCocoaErrorDomain)
    #expect(report.volumePropertiesError?.code == NSFileReadCorruptFileError)
    #expect(report.resolution.error != nil)
    #expect(report.scopeStarted == nil)
    #expect(report.listing == nil)
    #expect(report.classification.cause == .unknown)
}
