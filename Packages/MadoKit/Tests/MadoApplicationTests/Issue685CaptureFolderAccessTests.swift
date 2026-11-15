import Foundation
import Testing
import MadoCore
import MadoApplication

// #685 AC-5: Captures go to a non-default Capture Folder after a relaunch (the bookmark resolves); a stale bookmark is
// refreshed; one that cannot be resolved or opened falls back to ~/Downloads with a visible flag.

private enum BookmarkFailure: Error { case failed }

private final class FakeScope: SecurityScope, BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [URL] = []
    private var _stopped: [URL] = []
    var refuseAccess = false
    var resolveFails = false
    var createFails = false
    var staleOnResolve = false
    var created = 0
    var started: [URL] { lock.withLock { _started } }
    var stopped: [URL] { lock.withLock { _stopped } }
    func start(_ url: URL) -> Bool { lock.withLock { _started.append(url) }; return !refuseAccess }
    func stop(_ url: URL) { lock.withLock { _stopped.append(url) } }
    private var _gone: Set<URL> = []
    /// Folders renamed, deleted or unmounted since they were opened.
    var gone: Set<URL> {
        get { lock.withLock { _gone } }
        set { lock.withLock { _gone = newValue } }
    }
    func isReadable(_ url: URL) -> Bool { !gone.contains(url) }
    var requiresEmbeddedIdentity: Bool { false }
    func create(for url: URL) throws -> Data {
        if createFails { throw BookmarkFailure.failed }
        created += 1
        return Data("\(url.path)#\(created)".utf8)
    }
    func createFileGrant(for url: URL) throws -> Data { try create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if resolveFails { throw BookmarkFailure.failed }
        let path = String(decoding: data, as: UTF8.self).split(separator: "#")[0]
        return ResolvedBookmark(url: URL(fileURLWithPath: String(path), isDirectory: true), stale: staleOnResolve)
    }
}

private actor StoredFolder: CaptureFolderPreferencePort {
    var record = CaptureFolderRecord.downloads
    var writes = 0
    func folderRecord() -> CaptureFolderRecord { record }
    func setFolderRecord(_ record: CaptureFolderRecord) { self.record = record; writes += 1 }
}

private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
private let downloads = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)
private let shots = URL(fileURLWithPath: "/Users/someone/Pictures/Shots", isDirectory: true)

private func access(_ scope: FakeScope, _ stored: StoredFolder) -> CaptureFolderAccess {
    CaptureFolderAccess(scope: scope, preferences: stored, downloads: downloads, home: home)
}

@Test(.timeLimit(.minutes(2))) func issue685CaptureFolderDefaultsToDownloads() async {
    let scope = FakeScope()
    let stored = StoredFolder()
    let folder = access(scope, stored)
    #expect(await folder.currentFolder() == downloads)
    #expect(await folder.currentDisplay() == "~/Downloads")
    #expect(scope.started.isEmpty)
    #expect(await stored.writes == 0)
}

@Test(.timeLimit(.minutes(2))) func issue685ChosenFolderResolvesAgainAfterRelaunch() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    let first = access(scope, stored)
    try await first.choose(shots)
    #expect(await stored.record.display == "~/Pictures/Shots")
    #expect(await stored.record.bookmark != nil)
    #expect(await stored.record.fellBack == false)
    #expect(await first.currentFolder() == shots)
    #expect(await first.currentFolder() == shots)
    #expect(scope.started == [shots])  // opened once, kept open
    #expect(await first.currentDisplay() == "~/Pictures/Shots")

    let relaunchedScope = FakeScope()
    let relaunched = access(relaunchedScope, stored)
    #expect(await relaunched.currentFolder() == shots)
    #expect(relaunchedScope.started == [shots])
}

@Test(.timeLimit(.minutes(2))) func issue685ChoosingAnotherFolderClosesTheOldScope() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    let folder = access(scope, stored)
    try await folder.choose(shots)
    _ = await folder.currentFolder()
    let other = URL(fileURLWithPath: "/Volumes/Disk/Caps", isDirectory: true)
    try await folder.choose(other)
    #expect(scope.stopped == [shots])
    #expect(await folder.currentFolder() == other)
    #expect(await folder.currentDisplay() == "/Volumes/Disk/Caps")
}

@Test(.timeLimit(.minutes(2))) func issue685StaleBookmarkIsRefreshed() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    try await access(scope, stored).choose(shots)
    let before = await stored.record.bookmark
    scope.staleOnResolve = true
    let relaunched = access(scope, stored)
    #expect(await relaunched.currentFolder() == shots)
    let after = await stored.record.bookmark
    #expect(after != nil && after != before)
    #expect(await stored.record.fellBack == false)
    // A stale bookmark that cannot be recreated is still used this time.
    scope.createFails = true
    let again = access(scope, stored)
    #expect(await again.currentFolder() == shots)
    #expect(await stored.record.bookmark == after)
}

@Test(.timeLimit(.minutes(2))) func issue685UnresolvableBookmarkFallsBackToDownloadsAndSaysSo() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    try await access(scope, stored).choose(shots)
    scope.resolveFails = true
    let relaunched = access(scope, stored)
    #expect(await relaunched.currentFolder() == downloads)
    #expect(await relaunched.currentDisplay() == "~/Downloads")
    #expect(await stored.record.fellBack)
    #expect(await stored.record.display == "~/Pictures/Shots")  // Settings names the folder that failed
    let writes = await stored.writes
    _ = await relaunched.currentFolder()
    #expect(await stored.writes == writes)  // no rewrite while nothing changed
    // It is retried: once the bookmark resolves again the flag clears.
    scope.resolveFails = false
    #expect(await relaunched.currentFolder() == shots)
    #expect(await stored.record.fellBack == false)
}

@Test(.timeLimit(.minutes(2))) func issue685RefusedSecurityScopeFallsBackAndAChoiceClearsIt() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    let folder = access(scope, stored)
    try await folder.choose(shots)
    scope.refuseAccess = true
    #expect(await folder.currentFolder() == downloads)
    #expect(await stored.record.fellBack)
    scope.refuseAccess = false
    try await folder.choose(shots)
    #expect(await stored.record.fellBack == false)
    #expect(await folder.currentFolder() == shots)
}

@Test(.timeLimit(.minutes(2))) func issue685FailedChoiceKeepsTheCurrentFolder() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    let folder = access(scope, stored)
    try await folder.choose(shots)
    _ = await folder.currentFolder()
    scope.createFails = true
    await #expect(throws: BookmarkFailure.failed) {
        try await folder.choose(URL(fileURLWithPath: "/tmp/x", isDirectory: true))
    }
    #expect(await folder.currentFolder() == shots)
    #expect(await stored.record.display == "~/Pictures/Shots")
    #expect(scope.stopped.isEmpty)
}

@Test(.timeLimit(.minutes(2))) func issue685FolderDisplayAbbreviatesOnlyTheHomeFolder() {
    #expect(CaptureFolderAccess.display(home, home: home) == "~")
    #expect(CaptureFolderAccess.display(shots, home: home) == "~/Pictures/Shots")
    #expect(CaptureFolderAccess.display(URL(fileURLWithPath: "/Users/someoneelse/Downloads"), home: home)
            == "/Users/someoneelse/Downloads")
    #expect(CaptureFolderAccess.display(URL(fileURLWithPath: "/Users/someone/a/../Pictures"), home: home) == "~/Pictures")
}

private struct NamedFolderFiles: CaptureFilePort {
    func writeNewPNG(_ data: Data, named: String) async throws -> URL { shots.appendingPathComponent(named) }
    func folderDisplay() async -> String? { "~/Pictures/Shots" }
}

private struct PlainFiles: CaptureFilePort {
    func writeNewPNG(_ data: Data, named: String) async throws -> URL { downloads.appendingPathComponent(named) }
}

private struct OnePixel: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data([1]) }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data([1]) }
}

private struct NoClipboard: CaptureClipboardPort {
    func writePNG(_ png: Data) async -> Bool { true }
}

@Test(.timeLimit(.minutes(2))) func issue685ThumbnailStatusNamesTheCaptureFolder() async throws {
    let session = CaptureSession(screen: OnePixel(), files: NamedFolderFiles())
    let state = try await session.capture(request: nil, policy: .standard, clipboard: NoClipboard())
    #expect(state.folderDisplay == "~/Pictures/Shots")
    #expect(state.savedURL?.deletingLastPathComponent().path == shots.path)
    let plain = CaptureSession(screen: OnePixel(), files: PlainFiles())
    #expect(try await plain.capture(request: nil, policy: .standard, clipboard: NoClipboard()).folderDisplay == "~/Downloads")
    #expect(await PlainFiles().folderDisplay() == nil)
}

// Fix r1 (opus M1): a Capture Folder that disappears while the helper runs falls back to ~/Downloads with the note,
// instead of every capture failing to save until the helper restarts.
@Test(.timeLimit(.minutes(2))) func issue685FolderLostWhileTheHelperRunsFallsBackToDownloads() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    let folder = access(scope, stored)
    try await folder.choose(shots)
    #expect(await folder.currentFolder() == shots)
    // Renamed, deleted or unmounted in Finder, and its bookmark no longer resolves.
    scope.gone = [shots]
    scope.resolveFails = true
    #expect(await folder.currentFolder() == downloads)
    #expect(await folder.currentDisplay() == "~/Downloads")
    #expect(await stored.record.fellBack)
    #expect(await stored.record.display == "~/Pictures/Shots")
    #expect(scope.stopped == [shots])  // the lost folder's scope is closed
    // Each later capture tries the bookmark again; once the folder is back the note clears.
    scope.gone = []
    scope.resolveFails = false
    #expect(await folder.currentFolder() == shots)
    #expect(await stored.record.fellBack == false)
}

@Test(.timeLimit(.minutes(2))) func issue685BookmarkThatResolvesToAnUnreadableFolderFallsBack() async throws {
    let scope = FakeScope()
    let stored = StoredFolder()
    try await access(scope, stored).choose(shots)
    scope.gone = [shots]
    let relaunched = access(scope, stored)
    #expect(await relaunched.currentFolder() == downloads)
    #expect(await stored.record.fellBack)
    #expect(scope.stopped == [shots])
}
