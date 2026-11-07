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
        controller.openGrantedFolder(path.1)
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

/// Owner decision 2026-11-07 「Same as a plain folder (Recommended)」: a dropped or Open With folder, link or plain,
/// takes the folder panel prompt with its canonical target. The seam answers in place of the alert and NSOpenPanel.
@MainActor private final class Folder507Prompts {
    var folders: [URL] = []
    var answers: [(URL) -> Void] = []
}

/// The selection carries neither a startable scope nor process-level readability.
private struct Unreadable507Access: SecurityScope, BookmarkCoding {
    let system = SystemSecurityScope()
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
    func start(_ url: URL) -> Bool { false }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { false }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { try system.resolve(data) }
}

@MainActor private struct Delivered507Rig {
    let base: URL, actual: URL, symlink: URL, image: URL, rootsFile: URL
    let files: FileAccess, services: AccessServices
    let controller: CanvasWindowController, window: NSWindow
    let prompts = Folder507Prompts()
    /// The canonical target the prompt must preselect.
    var target: [String] { actual.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents }

    init(legacyScanner: Bool = false, unreadable: Bool = false) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("delivered507-\(UUID())", isDirectory: true)
        actual = URL(fileURLWithPath: base.appendingPathComponent("actual").path, isDirectory: false)
        symlink = URL(fileURLWithPath: base.appendingPathComponent("symlink").path, isDirectory: false)
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: actual)
        let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: asset)
        for index in 0..<3 { try data.write(to: actual.appendingPathComponent("\(index).png")) }
        image = base.appendingPathComponent("loose.png")
        try data.write(to: image)
        rootsFile = base.appendingPathComponent("roots.json")
        let scope: any SecurityScope & BookmarkCoding = unreadable ? Unreadable507Access() : SystemSecurityScope()
        files = try FileAccess(scope: scope, bookmarks: scope, store: BookmarkStore(url: rootsFile), buildSHA: "issue507-panel")
        services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()),
            selectionScope: scope)
        let services = services
        controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Alias507Motion()))
        controller.folderScanningOverride = Alias507Scanner(legacy: legacyScanner)
        window = try #require(controller.window)
        let prompts = prompts
        controller.folderGrantPromptOverride = { folder, selected in
            prompts.folders.append(folder); prompts.answers.append(selected)
        }
    }
    /// Polls with its own two-second wall-clock bound.
    func within2s(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            window.update()
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    func expectNothingGranted(_ label: String) async throws {
        #expect(await files.records().isEmpty, "\(label): no Access Root before the panel grants")
        #expect(!FileManager.default.fileExists(atPath: rootsFile.path), "\(label): no bookmark stored")
        #expect(try await services.recent.load().isEmpty, "\(label): no recent entry")
    }
    func remove() {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        window.close()
        try? FileManager.default.removeItem(at: base)
    }
}

@Test(arguments: [false, true]) @MainActor
func issue507DeliveredFoldersTakeTheFolderPanel(legacyScanner: Bool) async throws {
    for entry in ["drop raw symlink", "drop plain folder", "open -a symlink", "open -a plain folder"] {
        let rig = try Delivered507Rig(legacyScanner: legacyScanner)
        defer { rig.remove() }
        let selected: URL = switch entry {
        case "drop raw symlink": rig.symlink
        case "drop plain folder": rig.actual
        case "open -a symlink": URL(fileURLWithPath: rig.symlink.path, isDirectory: true)
        default: URL(fileURLWithPath: rig.actual.path, isDirectory: true)
        }
        rig.controller.openInput([selected])
        let prompted = try await rig.within2s { !rig.prompts.folders.isEmpty }
        #expect(prompted, "\(entry): the folder panel prompt must appear")
        guard prompted else { continue }
        let folder = rig.prompts.folders[0]
        #expect(folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents == rig.target,
            "\(entry): the prompt preselects the canonical target, got \(folder.path)")
        #expect(folder.path == folder.resolvingSymlinksInPath().path, "\(entry): the prompted folder is already canonical")
        #expect(rig.controller.session.folderScan == nil, "\(entry): nothing scans before the grant")
        try await rig.expectNothingGranted(entry)
        // The simulated panel grants the folder it was opened on.
        rig.prompts.answers[0](folder)
        let completed = try await rig.within2s {
            rig.controller.session.folderScan?.sourceSnapshot?.isComplete == true &&
                rig.controller.session.folderScan?.isScanning == false && rig.controller.gridSearchAvailable
        }
        let scan = rig.controller.session.folderScan
        #expect(completed, "\(entry): the grid must complete within 2 seconds of the grant")
        #expect(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
        #expect(rig.prompts.folders.count == 1, "\(entry): one prompt only")
        #expect(rig.window.attachedSheet == nil, "\(entry): no second sheet")
        #expect(await rig.files.records().count == 1)
        #expect(try await rig.services.recent.load().first?.displayName == "actual")
        #expect(rig.window.title == "actual")
    }
}

@Test @MainActor
func issue507CancelledFolderPanelLeavesNoGrant() async throws {
    let rig = try Delivered507Rig()
    defer { rig.remove() }
    rig.controller.openInput([rig.symlink])
    #expect(try await rig.within2s { !rig.prompts.folders.isEmpty }, "the folder panel prompt must appear")
    // Cancel: the prompt never answers.
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.prompts.folders.count == 1)
    #expect(rig.controller.session.folderScan == nil)
    try await rig.expectNothingGranted("cancel")
}

@Test @MainActor
func issue507UnreadableDeliveredFolderKeepsTheSelectedURLForThePrompt() async throws {
    let rig = try Delivered507Rig(unreadable: true)
    defer { rig.remove() }
    let selected = URL(fileURLWithPath: rig.actual.path, isDirectory: true)
    rig.controller.openInput([selected])
    #expect(try await rig.within2s { !rig.prompts.folders.isEmpty }, "a hinted folder still reaches the prompt")
    #expect(rig.prompts.folders.first == selected)
    try await rig.expectNothingGranted("unreadable")
}

@Test(arguments: ["image", "link and image", "stale link"]) @MainActor
func issue507NonFolderInputNeverPromptsForAFolder(input: String) async throws {
    let rig = try Delivered507Rig()
    defer { rig.remove() }
    switch input {
    case "image": rig.controller.openInput([rig.image])
    case "link and image": rig.controller.openInput([rig.symlink, rig.image])
    default:
        // A newer input replaces the folder drop before its classification returns.
        rig.controller.openInput([rig.symlink])
        rig.controller.openInput([rig.image])
    }
    #expect(try await rig.within2s { rig.controller.session.imageStatus == .showing }, "\(input): the image opens")
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.prompts.folders.isEmpty, "\(input): no folder prompt")
    try await rig.expectNothingGranted(input)
}
