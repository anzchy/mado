import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private struct Issue610Fixture {
    let base: URL
    let file: URL
    let bytes = Data([6, 1, 0, 255])
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        file = base.appendingPathComponent("before.png")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    var store: BookmarkStore { BookmarkStore(url: base.appendingPathComponent("roots.json")) }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

/// Only the native authorization boundary is constrained. Accepted requests still
/// create real Foundation bookmark data; this does not emulate App Sandbox itself.
private final class Issue610NativeBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(URL.BookmarkCreationOptions, Set<URLResourceKey>?)] = []
    func create(_ url: URL, options: URL.BookmarkCreationOptions, keys: Set<URLResourceKey>?) throws -> Data {
        lock.withLock { requests.append((options, keys)) }
        guard options.contains(.withSecurityScope), options.contains(.securityScopeAllowOnlyReadAccess) else {
            throw CocoaError(.fileReadUnknown)
        }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: keys, relativeTo: nil)
    }
    var observations: [(URL.BookmarkCreationOptions, Set<URLResourceKey>?)] { lock.withLock { requests } }
    var creation: SecurityScopedBookmarkCreation {
        SecurityScopedBookmarkCreation(bookmarkData: { [self] url, options, keys in
            try create(url, options: options, keys: keys)
        })
    }
}

private final class Issue610Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, URL?)] = []
    func append(_ message: String, _ path: URL?) { lock.withLock { events.append((message, path)) } }
    var observations: [(String, URL?)] { lock.withLock { events } }
}

@Test(.timeLimit(.minutes(2))) func issue610ReadOnlyFileGrantTracksRename() async throws {
    let f = try Issue610Fixture(); defer { f.remove() }
    let native = Issue610NativeBoundary()
    let codec = SystemSecurityScope(bookmarkCreation: native.creation)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "issue610")
    let first = try await access.acquire(.fileGrant(f.file))
    #expect(try Data(contentsOf: first.url) == f.bytes)
    await access.release(first)
    let moved = f.base.appendingPathComponent("after.png")
    try FileManager.default.moveItem(at: f.file, to: moved)
    let resolved = try await access.resolveFileGrant(f.file)
    #expect(resolved.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
    if FileManager.default.fileExists(atPath: resolved.path) {
        let second = try await access.acquire(.fileGrant(f.file))
        #expect(second.url.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: second.url) == f.bytes)
        await access.release(second)
    }
    let requests = native.observations
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.0.contains(.withSecurityScope) && $0.0.contains(.securityScopeAllowOnlyReadAccess) })
    let identityKeys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey, .fileResourceIdentifierKey]
    #expect(requests.allSatisfy { Set($0.1 ?? []) == identityKeys })
    #expect(await access.records().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.store.url.path))
    #expect(scope.counts[0] == scope.counts[1])
}

@Test(arguments: [false, true])
func issue610SystemBookmarkIdentityRoundTrip(isDirectory: Bool) throws {
    let f = try Issue610Fixture(); defer { f.remove() }
    let resource = isDirectory ? f.base : f.file
    let codec = SystemSecurityScope()
    let bookmark = try codec.create(for: resource)
    #expect(!bookmark.isEmpty)
    let resolved = try codec.resolve(bookmark)
    #expect(resolved.url.resolvingSymlinksInPath().path == resource.resolvingSymlinksInPath().path)
    let expected = try #require(try URLIdentityResourceReader().identity(for: resource))
    let embedded = try #require(AccessProbeFactGatherer.bookmarkIdentity(in: bookmark))
    #expect(embedded == expected)
}

@Test(arguments: [false, true])
func issue610ProbeReadOnlyBookmarksRoundTrip(enriched: Bool) throws {
    let f = try Issue610Fixture(); defer { f.remove() }
    let native = Issue610NativeBoundary()
    let gatherer = AccessProbeFactGatherer(bookmarkCreation: native.creation)
    var bookmark: Data?
    do { bookmark = try gatherer.makeBookmark(for: f.base, storingVolumeProperties: enriched) }
    catch { Issue.record("Read-only native creation must succeed; kind=\(AccessDiagnostics.errorKind(error))") }
    if let bookmark {
        #expect(!bookmark.isEmpty)
        let report = gatherer.gather(bookmarkData: bookmark)
        #expect(report.resolution.url?.resolvingSymlinksInPath().path == f.base.resolvingSymlinksInPath().path)
        #expect(report.listing?.entryCount == 1)
        #expect(report.classification.cause == .readable)
        if enriched {
            #expect(report.volume.uuid == (try f.base.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString))
        }
    }
    let requests = native.observations
    #expect(requests.count == 1)
    #expect(requests.allSatisfy { $0.0.contains(.withSecurityScope) && $0.0.contains(.securityScopeAllowOnlyReadAccess) })
    if enriched {
        #expect(requests.allSatisfy { Set($0.1 ?? []) == [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey] })
    } else {
        #expect(requests.allSatisfy { $0.1 == nil })
    }
}

@Test(arguments: [0, 1, 2])
func issue610NativeBookmarkCreationFailurePreservesError(route: Int) throws {
    let f = try Issue610Fixture(); defer { f.remove() }
    let creation = SecurityScopedBookmarkCreation(bookmarkData: { _, _, _ in
        throw NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13),
            NSLocalizedDescriptionKey: "private native description",
        ])
    })
    do {
        if route == 0 { _ = try SystemSecurityScope(bookmarkCreation: creation).create(for: f.file) }
        else { _ = try AccessProbeFactGatherer(bookmarkCreation: creation).makeBookmark(for: f.base, storingVolumeProperties: route == 2) }
        Issue.record("Native creation failure must be forwarded")
    } catch {
        let native = error as NSError
        #expect(native.domain == NSCocoaErrorDomain)
        #expect(native.code == 256)
        let underlying = try #require(native.userInfo[NSUnderlyingErrorKey] as? NSError)
        #expect(underlying.domain == NSPOSIXErrorDomain)
        #expect(underlying.code == 13)
        #expect(AccessDiagnostics.errorKind(error) == "NSCocoaErrorDomain:256,NSPOSIXErrorDomain:13")
    }
}

@Test(.timeLimit(.minutes(2))) func issue610FailedBookmarkCreationDoesNotInventTrash() async throws {
    try await issue610FailedBookmarkCreation(trash: false)
}

#if MADO_TRASH_INTEGRATION
// #672: real DesktopServices Trash; runs only in `node scripts/tdd/trash-lane.mjs`.
@Test(.timeLimit(.minutes(2))) func issue610FailedBookmarkCreationDoesNotInventRealTrash() async throws {
    try await issue610FailedBookmarkCreation(trash: true)
}
#endif

/// #672: the removal case stays in the default lane; the real-Trash case is integration only.
private func issue610FailedBookmarkCreation(trash: Bool) async throws {
    let f = try Issue610Fixture(); defer { f.remove() }
    let codec = SystemSecurityScope(bookmarkCreation: SecurityScopedBookmarkCreation(bookmarkData: { _, _, _ in
        throw CocoaError(.fileReadUnknown)
    }))
    let scope = CountingScope(), messages = Issue610Diagnostics()
    let access = try FileAccess(scope: scope, bookmarks: codec, store: f.store, buildSHA: "issue610-failure",
        diagnostics: AccessDiagnostics(sink: { messages.append($0, $1) }))
    let first = try await access.acquire(.fileGrant(f.file))
    #expect(try Data(contentsOf: first.url) == f.bytes)
    await access.release(first)
    var trashed: NSURL?
    defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }
    #if MADO_TRASH_INTEGRATION
    if trash { try FileManager.default.trashItem(at: f.file, resultingItemURL: &trashed) }
    else { try FileManager.default.removeItem(at: f.file) }
    #else
    precondition(!trash, "the real-Trash case compiles only with MADO_TRASH_INTEGRATION")
    try FileManager.default.removeItem(at: f.file)
    #endif
    let resolved = try await access.resolveFileGrant(f.file)
    #expect(resolved == f.file)
    #expect(throws: (any Error).self) { try Data(contentsOf: resolved) }
    #expect(messages.observations.contains { $0.0 == "FileGrantBookmark stage=create outcome=failed kind=NSCocoaErrorDomain:256" && $0.1 == nil })
    #expect(messages.observations.allSatisfy { $0.1 == nil })
    #expect(await access.records().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.store.url.path))
    #expect(scope.counts[0] == scope.counts[1])
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func issue610RetainedBookmarkLossRemainsReconnection(scopeDenied: Bool) async throws {
    let f = try Issue610Fixture(); defer { f.remove() }
    let native = Issue610NativeBoundary(), scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(bookmarkCreation: native.creation),
        store: f.store, buildSHA: "issue610-loss")
    let first = try await access.acquire(.fileGrant(f.file))
    await access.release(first)
    if scopeDenied {
        scope.succeeds = false
        await #expect(throws: FileAccessError.needsFileReconnection(f.file)) {
            _ = try await access.acquire(.fileGrant(f.file))
        }
        #expect(scope.counts == [2, 1])
    } else {
        try FileManager.default.removeItem(at: f.file)
        await #expect(throws: FileAccessError.needsFileReconnection(f.file)) {
            _ = try await access.resolveFileGrant(f.file)
        }
        #expect(scope.counts[0] == scope.counts[1])
    }
    #expect(await access.records().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.store.url.path))
}
