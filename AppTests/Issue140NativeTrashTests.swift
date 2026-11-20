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

/// The real security scope and bookmarks, except that an armed `failResolve` makes every bookmark resolution fail,
/// as when access to a File Grant is really lost (#785).
private final class ArmedFileGrantBookmarks: SecurityScope, BookmarkCoding, @unchecked Sendable {
    private let system = SystemSecurityScope()
    private let lock = NSLock()
    private var failing = false
    func failResolve() { lock.withLock { failing = true } }
    func start(_ url: URL) -> Bool { system.start(url) }
    func stop(_ url: URL) { system.stop(url) }
    func isReadable(_ url: URL) -> Bool { system.isReadable(url) }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func createFileGrant(for url: URL) throws -> Data { try system.createFileGrant(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if lock.withLock({ failing }) { throw CocoaError(.fileReadNoSuchFile) }
        return try system.resolve(data)
    }
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
}

/// A File Grant viewer whose identity reads and bookmarks the test controls. It has no vnode watch (the existing
/// foreground-only mode), so only the paths under test reconcile: no watch event can recover or clear the image.
@MainActor private struct ForcedOrderViewer {
    let base: URL
    let file: URL
    let reader = TrashOnIdentityReader()
    let bookmarks = ArmedFileGrantBookmarks()
    let controller: CanvasWindowController
    let window: NSWindow
    let recorder: ReconnectSheetRecorder
    /// The read probe each deferred loader failure started, in order.
    let deferred = DeferredProbes()

    init() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("image.png")
        try fm.copyItem(at: issue140Fixture("landscape-3x2.png"), to: file)
        let access = try FileAccess(scope: bookmarks, bookmarks: bookmarks,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-forced-order",
            resourceReader: reader)
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: TrashTestMotionSource()))
        controller.fileGrantWatchOpener = { _ in -1 }
        window = try #require(controller.window)
        recorder = ReconnectSheetRecorder(controller)
        let deferred = deferred
        controller.fileGrantReadFailureDeferred = { deferred.probes.append($0) }
    }

    /// Opens the File Grant and waits until it is displayed, settled and reconciled.
    func openSettled() async throws {
        controller.open(file, accessRequest: .fileGrant(file))
        try await waitUntil("first open settled") { controller.session.imageLoader.phase == .settled }
        await controller.waitForStandaloneReconciliation()
        try await waitUntil("settled after reconciliation") { controller.session.imageLoader.phase == .settled }
    }

    /// Waits until the loader's failure has been handled: deferred, reconnected, cleared, or left failed.
    func loaderFailureHandled() async throws {
        try await waitUntil("the loader failure was handled") {
            controller.session.imageLoader.phase == .failed || !deferred.probes.isEmpty
                || window.attachedSheet != nil || controller.session.imageLoader.fileURL == nil
        }
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
        if let moved = reader.trashed { try? FileManager.default.removeItem(at: moved) }
        try? FileManager.default.removeItem(at: base)
    }
}

@MainActor private final class DeferredProbes { var probes: [Task<Void, Never>] = [] }

private func issue140Fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/\(name)")
}

/// #785 forced ordering: the displayed File Grant image's loader asks for access, and the Trash rename lands between
/// the grant's path check and its identity read. Only the loader asks: a re-open from a folder scan starts no root
/// check and no reconciliation, and there is no vnode watch. The loader's failure must go to the read probe, and the
/// probe alone clears the trashed file without the reconnect sheet (#140); nothing here nudges a reconciliation.
@Test(.timeLimit(.minutes(3))) @MainActor func issue140LoaderAccessRacingTheTrashRenameClearsWithoutReconnectSheet() async throws {
    let viewer = try ForcedOrderViewer()
    defer { viewer.close() }
    try await viewer.openSettled()
    viewer.reader.arm(viewer.file)
    viewer.controller.open(viewer.file, accessRequest: .fileGrant(viewer.file), fromFolderScan: true)
    try await waitUntil("the loader's access request read the armed identity") { viewer.reader.fired }
    #expect(viewer.reader.failure == nil)
    #expect(!FileManager.default.fileExists(atPath: viewer.file.path))
    try await viewer.loaderFailureHandled()
    let probe = try #require(viewer.deferred.probes.first,
        "the loader failure was not deferred to the read probe: \(viewer.recorder.report(viewer.controller, viewer.window))")
    await probe.value
    #expect(viewer.deferred.probes.count == 1)
    #expect(viewer.controller.session.imageLoader.fileURL == nil)
    #expect(viewer.window.representedURL == nil)
    #expect(viewer.window.attachedSheet == nil, "\(viewer.recorder.reportIfSheet(viewer.controller, viewer.window))")
    #expect(viewer.recorder.requests.isEmpty, "\(viewer.recorder.report(viewer.controller, viewer.window))")
}

/// gpt M1: the Trash move fails the loader, then another app puts a readable replacement at the same path before the
/// read probe runs. The probe finds the granted path readable again, so the viewer shows the replacement (#140's
/// replacement behaviour) instead of staying failed and blank.
@Test(.timeLimit(.minutes(3))) @MainActor func issue140SamePathReplacementBeforeTheDeferredProbeShowsTheReplacement() async throws {
    let viewer = try ForcedOrderViewer()
    defer { viewer.close() }
    try await viewer.openSettled()
    let original = try #require(viewer.controller.session.imageLoader.presented)
    let replacement = issue140Fixture("portrait-2x3.png")
    let file = viewer.file
    let deferred = viewer.deferred
    // Runs synchronously inside imageLoadFailed, before the probe's task body starts.
    viewer.controller.fileGrantReadFailureDeferred = { probe in
        deferred.probes.append(probe)
        try? FileManager.default.copyItem(at: replacement, to: file)
    }
    viewer.reader.arm(file)
    viewer.controller.open(file, accessRequest: .fileGrant(file), fromFolderScan: true)
    try await waitUntil("the loader's access request read the armed identity") { viewer.reader.fired }
    try await viewer.loaderFailureHandled()
    let probe = try #require(deferred.probes.first,
        "the loader failure was not deferred to the read probe: \(viewer.recorder.report(viewer.controller, viewer.window))")
    await probe.value
    await viewer.controller.waitForStandaloneReconciliation()
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(viewer.controller.session.imageLoader.phase != .failed,
            "the readable replacement left the viewer failed: \(viewer.recorder.report(viewer.controller, viewer.window))")
    if viewer.controller.session.imageLoader.phase != .failed {
        try await waitUntil("the replacement is presented") {
            if let presented = viewer.controller.session.imageLoader.presented,
               presented.key.revision != original.key.revision { return true }
            return false
        }
        #expect(viewer.controller.session.imageLoader.presented?.fileURL.standardizedFileURL == file.standardizedFileURL)
        #expect(viewer.window.representedURL?.standardizedFileURL == file.standardizedFileURL)
    }
    #expect(viewer.window.attachedSheet == nil, "\(viewer.recorder.reportIfSheet(viewer.controller, viewer.window))")
    #expect(viewer.recorder.requests.isEmpty, "\(viewer.recorder.report(viewer.controller, viewer.window))")
}

/// gpt M2 / opus M1: lost access is not swallowed. The display path is gone and the grant's bookmark no longer
/// resolves; the loader's needsFileReconnection goes to the read probe, and the probe asks to reconnect once.
@Test(.timeLimit(.minutes(3))) @MainActor func issue140DeferredLoaderFailureWithLostAccessStillAsksToReconnect() async throws {
    let viewer = try ForcedOrderViewer()
    defer { viewer.close() }
    try await viewer.openSettled()
    viewer.bookmarks.failResolve()
    try FileManager.default.removeItem(at: viewer.file)
    viewer.controller.imageLoadFailed(FileAccessError.needsFileReconnection(viewer.file))
    let probe = try #require(viewer.deferred.probes.first, "the loader failure was not deferred to the read probe")
    await probe.value
    #expect(viewer.deferred.probes.count == 1)
    #expect(viewer.window.attachedSheet != nil)
    #expect(sheetText(viewer.window).contains("[Choose File Again…]"), "\(viewer.recorder.report(viewer.controller, viewer.window))")
    #expect(viewer.recorder.requests.count == 1, "\(viewer.recorder.report(viewer.controller, viewer.window))")
    #expect(viewer.recorder.requests.first?.hasPrefix("reportFileGrantReadFailure") == true,
            "\(viewer.recorder.report(viewer.controller, viewer.window))")
}
