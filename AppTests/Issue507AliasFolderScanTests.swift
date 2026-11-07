import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

private final class Alias507Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    func report() -> String { lock.withLock { events.joined(separator: ", ") } }
}


private struct Alias507SystemAccess: SecurityScope, BookmarkCoding {
    let events: Alias507Events
    let system = SystemSecurityScope()
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
    func start(_ url: URL) -> Bool { let result = system.start(url); events.append("system scope start=\(result)"); return result }
    func stop(_ url: URL) { system.stop(url) }
    func isReadable(_ url: URL) -> Bool { system.isReadable(url) }
    func create(for url: URL) throws -> Data {
        do { let data = try system.create(for: url); events.append("system bookmark created"); return data }
        catch { events.append("system bookmark create threw \(error)"); throw error }
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        do { let result = try system.resolve(data); events.append("system bookmark resolved \(result.url.absoluteString)"); return result }
        catch { events.append("system bookmark resolve threw \(error)"); throw error }
    }
}

/// Observe the real scan boundary; the legacy mode recreates #506's one-batch test scanner.
private actor Alias507Scanner: FolderScanning {
    let legacy: Bool
    private let events = Alias507Events()
    init(legacy: Bool) { self.legacy = legacy }
    nonisolated func report() -> String { events.report() }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        events.append("scan entered")
        do {
            if legacy {
                // Match FolderBrowser's directory-target normalization while the
                // coordinator already holds the actual root lease.
                let scanFolder = folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
                let entries = try FileManager.default.contentsOfDirectory(at: scanFolder, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "png" }.map { FolderEntry(url: $0, root: root) }
                try await deliver(entries, emit: emit)
            } else {
                try await FolderBrowser().scan(in: folder, root: root, options: options) { entries in
                    try await self.deliver(entries, emit: emit)
                }
            }
            events.append("scan returned")
        } catch { events.append("scan threw: \(error)"); throw error }
    }
    private func deliver(_ entries: [FolderEntry], emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        events.append("emit \(entries.count) entered")
        try await emit(entries)
        events.append("emit returned")
    }
}

@MainActor private final class Alias507Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Each case has its own two-second wall-clock bound, independent of ConditionWait's timed-test policy.
@Test(arguments: [false, true]) @MainActor
func issue507FolderPathsComplete(legacyScanner: Bool) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("alias507-\(UUID())")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual"), symlink = base.appendingPathComponent("symlink")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: symlink, withDestinationURL: actual)
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: asset)
    for index in 0..<3 { try data.write(to: actual.appendingPathComponent("\(index).png")) }
    var paths: [(String, URL)] = [("direct", actual), ("symlink", symlink),
        ("symlink (directory URL)", base.appendingPathComponent("symlink", isDirectory: true))]
    let alias = base.appendingPathComponent("Finder alias")
    do {
        let bookmark = try actual.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        // The native folder chooser resolves Finder aliases before openGrantedFolder receives its URL.
        #expect(NSOpenPanel().resolvesAliases)
        let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
        #expect(resolved.resolvingSymlinksInPath().standardizedFileURL == actual.standardizedFileURL)
        paths.append(("Finder alias (chooser-resolved)", resolved))
    } catch {
        print("[i507] Finder alias fixture unavailable: \(error)")
    }
    paths.append(("drop/Open With raw symlink", symlink))
    paths.append(("drop/Open With directory symlink", base.appendingPathComponent("symlink", isDirectory: true)))
    for (index, path) in paths.enumerated() {
        let events = Alias507Events()
        let adapter = Alias507SystemAccess(events: events)
        let access = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: base.appendingPathComponent("roots-\(index).json")), buildSHA: "issue507")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent-\(index).json")),
            browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Alias507Motion()))
        let scanner = Alias507Scanner(legacy: legacyScanner)
        controller.folderScanningOverride = scanner
        let window = try #require(controller.window)
        if path.0.hasPrefix("drop/Open With") { controller.openInput([path.1]) }
        else { controller.openGrantedFolder(path.1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline && !Task.isCancelled {
            if controller.session.folderScan?.sourceSnapshot?.isComplete == true,
               controller.session.folderScan?.isScanning == false, controller.gridSearchAvailable { break }
            window.update()
            try await Task.sleep(for: .milliseconds(5))
        }
        let scan = controller.session.folderScan
        let diagnostic = "\(path.0), legacy=\(legacyScanner): \(scanner.report()); scanExists=\(scan != nil), scanning=\(scan?.isScanning ?? false), complete=\(scan?.sourceSnapshot?.isComplete ?? false), count=\(scan?.sourceSnapshot?.navigationEntries.count ?? -1), gridReady=\(controller.gridSearchAvailable), failure=\(String(describing: scan?.failure))"
        print("[i507] \(diagnostic)")
        print("[i507] access \(path.0): \(events.report()); sheet=\(window.attachedSheet != nil)")
        #expect(scan?.sourceSnapshot?.isComplete == true, "Scan did not complete within 2 seconds: \(diagnostic)")
        #expect(scan?.isScanning == false, "Scan remained active: \(diagnostic)")
        #expect(scan?.sourceSnapshot?.navigationEntries.count == 3, "Paths must return the same three images: \(diagnostic)")
        #expect(controller.gridSearchAvailable, "Completion did not reach the grid: \(diagnostic)")
        #expect(window.attachedSheet == nil, "Selection must not require another grant: \(diagnostic)")
        #expect(window.title == path.1.lastPathComponent)
        let recent = try await services.recent.load()
        #expect(recent.first?.displayName == path.1.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent)
        #expect(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
        window.close()
    }
}

@Test @MainActor
func issue507EquivalentGrantsKeepOneRootAndRejectMissingTarget() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("grants507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual", isDirectory: true)
    let link = base.appendingPathComponent("selected-link")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: actual)
    let image = actual.appendingPathComponent("one.png")
    try Data([1, 2, 3]).write(to: image)
    let system = SystemSecurityScope()
    let files = try FileAccess(scope: system, bookmarks: system,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue507")
    let direct = try await files.grant(folder: actual)
    let linked = try await files.grant(folder: link)
    let repeated = try await files.grant(folder: link)
    #expect(direct == linked && linked == repeated)
    #expect(await files.records().count == 1)
    let data = try await files.withLease(.root(linked, file: link.appendingPathComponent("one.png"))) { _ in
        try Data(contentsOf: image)
    }
    #expect(data == Data([1, 2, 3]))
    let dangling = base.appendingPathComponent("dangling")
    try fm.createSymbolicLink(at: dangling, withDestinationURL: base.appendingPathComponent("absent"))
    await #expect(throws: (any Error).self) { try await files.grant(folder: dangling) }
    #expect(await files.records().count == 1)
}

@Test @MainActor
func issue507LinkedFirstGrantKeepsCanonicalRootIdentity() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("linked-first507-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual", isDirectory: true)
    let link = base.appendingPathComponent("selected-link")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: actual)
    let system = SystemSecurityScope()
    let files = try FileAccess(scope: system, bookmarks: system,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue507-linked-first")
    let linked = try await files.grant(folder: link)
    let direct = try await files.grant(folder: actual)
    #expect(linked == direct)
    #expect(await files.records().count == 1)
    #expect(try await files.verifyExplicitSelection(direct).resolvingSymlinksInPath().path == actual.path)
}
