import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class TrashTestMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor func sheetText(_ window: NSWindow) -> String {
    guard let sheet = window.attachedSheet else { return "" }
    // Button titles in brackets tell the File Grant reconnect alert ("Choose File Again…") from the input notice ("OK").
    func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? (view as? NSButton).map { ["[\($0.title)]"] } ?? [])
            + view.subviews.flatMap(texts)
    }
    return sheet.contentView.map(texts)?.filter { !$0.isEmpty }.joined(separator: " | ") ?? ""
}

/// #785: records every reconnect request (calling path, line, error) so a sheet names the path that attached it.
@MainActor final class ReconnectSheetRecorder {
    private(set) var requests: [String] = []
    init(_ controller: CanvasWindowController) {
        controller.fileReconnectionTrace = { [weak self] in self?.requests.append($0) }
    }
    func report(_ controller: CanvasWindowController, _ window: NSWindow) -> String {
        let paths = requests.isEmpty ? "none (the sheet did not come from requestFileReconnection)"
            : requests.joined(separator: " ; ")
        return "sheet: \(sheetText(window)); reconnect requests: \(paths); loader phase: "
            + "\(controller.session.imageLoader.phase); loader file: \(controller.session.imageLoader.fileURL?.lastPathComponent ?? "nil")"
    }
    /// Prints on stdout as well, so CI's uploaded first-attempt log keeps the path even if the expectation text is cut.
    func reportIfSheet(_ controller: CanvasWindowController, _ window: NSWindow) -> String {
        let text = report(controller, window)
        if window.attachedSheet != nil { print("issue140 reconnect sheet attached: \(text)") }
        return text
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue140DisplayedFileGrantTrashClearsWithoutReconnectSheet() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try fm.copyItem(at: fixture, to: file)
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-native-trash")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: TrashTestMotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let recorder = ReconnectSheetRecorder(controller)
    controller.open(file, accessRequest: .fileGrant(file))
    try await waitUntil { controller.session.imageLoader.presented != nil }
    #expect(controller.session.imageLoader.presented != nil)
    var trashed: NSURL?
    try fm.trashItem(at: file, resultingItemURL: &trashed)
    defer { if let trashed { try? fm.removeItem(at: trashed as URL) } }
    try await waitUntil {
        if controller.session.imageLoader.fileURL == nil { return true }
        controller.reconcileStandaloneImage()
        return false
    }
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(window.representedURL == nil)
    #expect(window.attachedSheet == nil, "\(recorder.reportIfSheet(controller, window))")
}

/// The real identity reader, except that once armed for a path, its next identity read of that path first moves the
/// file to the Trash. The Trash rename then lands exactly between FileAccess seeing the File Grant's path exist and
/// reading its identity, the window a displayed image's loader can hit while the user trashes the file (#785).
private final class TrashOnIdentityReader: FileIdentityResourceReading, @unchecked Sendable {
    private let real = URLIdentityResourceReader()
    private let lock = NSLock()
    private var armed: URL?
    private var movedTo: URL?
    private var moveError: String?
    func arm(_ url: URL) { lock.withLock { armed = url.standardizedFileURL } }
    var fired: Bool { lock.withLock { movedTo != nil || moveError != nil } }
    var trashed: URL? { lock.withLock { movedTo } }
    var failure: String? { lock.withLock { moveError } }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        let fire = lock.withLock { () -> Bool in
            guard armed == fileURL.standardizedFileURL else { return false }
            armed = nil
            return true
        }
        if fire {
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: &result)
                lock.withLock { movedTo = (result as URL?) ?? fileURL }
            } catch { lock.withLock { moveError = String(describing: error) } }
        }
        return try real.identity(for: fileURL)
    }
}

/// #785 forced ordering: the displayed File Grant image's loader asks for access, and the Trash rename lands between
/// the grant's path check and its identity read. Only the loader asks: a re-open from a folder scan starts no root
/// check, no watch and no reconciliation. #140: a trashed file clears without the reconnect sheet.
@Test(.timeLimit(.minutes(3))) @MainActor func issue140LoaderAccessRacingTheTrashRenameClearsWithoutReconnectSheet() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try fm.copyItem(at: fixture, to: file)
    let scope = SystemSecurityScope()
    let reader = TrashOnIdentityReader()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-forced-order",
        resourceReader: reader)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: TrashTestMotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let recorder = ReconnectSheetRecorder(controller)
    controller.open(file, accessRequest: .fileGrant(file))
    try await waitUntil("first open settled") { controller.session.imageLoader.phase == .settled }
    await controller.waitForStandaloneReconciliation()
    try await waitUntil("settled after reconciliation") { controller.session.imageLoader.phase == .settled }
    defer { if let moved = reader.trashed { try? fm.removeItem(at: moved) } }
    reader.arm(file)
    controller.open(file, accessRequest: .fileGrant(file), fromFolderScan: true)
    try await waitUntil("the loader's access request read the armed identity") { reader.fired }
    #expect(reader.failure == nil)
    #expect(!fm.fileExists(atPath: file.path))
    try await waitUntil("the loader failed or cleared") {
        controller.session.imageLoader.phase == .failed || controller.session.imageLoader.fileURL == nil
    }
    try await waitUntil("the image cleared") {
        if controller.session.imageLoader.fileURL == nil { return true }
        controller.reconcileStandaloneImage()
        return false
    }
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(window.representedURL == nil)
    #expect(window.attachedSheet == nil, "\(recorder.reportIfSheet(controller, window))")
    #expect(recorder.requests.isEmpty, "\(recorder.report(controller, window))")
}
