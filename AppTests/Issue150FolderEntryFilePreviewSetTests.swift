import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private struct Issue150Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        guard let path = String(data: data, encoding: .utf8) else { throw FileAccessError.corruptStore }
        return ResolvedBookmark(url: URL(fileURLWithPath: path), stale: false)
    }
}

/// Holds the folder in its reading state until the scan is cancelled, so Cancel Reading never races completion.
private struct Issue150HoldingScanner: FolderScanning {
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

@MainActor private final class Issue150MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Shared with Issue150FolderEntryCloseTests.
@MainActor struct Issue150Scene {
    let base: URL, folder: URL, files: [URL]
    let services: AccessServices
    let controller: CanvasWindowController
    let window: NSWindow
    let router = CommandRouter()

    init() async throws {
        _ = NSApplication.shared
        base = FileManager.default.temporaryDirectory.appendingPathComponent("issue150-\(UUID().uuidString)")
        folder = base.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("z.png"))
        let base = base
        files = try ["f0.png", "f1.png", "f2.png"].map {
            let url = base.appendingPathComponent($0)
            try Data().write(to: url)
            return url
        }
        let adapter = Issue150Bookmarks()
        let access = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue150")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        self.services = services
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: Issue150MotionSource()))
        window = try #require(controller.window)
        let scan = FolderScanCoordinator(access: access, scanner: Issue150HoldingScanner(),
            trace: nil, metadataReader: nil)
        scan.host = controller
        controller.session.folderScan = scan
    }

    /// Opens the files as a File Preview Set and moves to the middle one.
    func openFilePreviewSetAtMiddle() async throws {
        controller.openInput(files)
        try await waitUntil { controller.session.filePreviewSet != nil }
        #expect(router.route(.next, from: .key, to: controller.session))
        #expect(controller.session.filePreviewSet?.index == 1)
    }
    func waitUntilReading() async throws {
        try await waitUntil {
            controller.session.mode == .browsing && controller.session.folderScan?.isReadingFolder == true
        }
    }
    func cancelReading() async throws {
        try await waitUntil { Self.button("state.cancel-folder", in: window.contentView) != nil }
        let button = try #require(Self.button("state.cancel-folder", in: window.contentView))
        button.performClick(nil)
    }
    /// Cancel Reading put the same set back: same files, same Current Item, and ←/→ walk it in order.
    func expectSetRestoredAtMiddle() {
        let session = controller.session
        #expect(session.mode == .viewing)
        #expect(session.filePreviewSet?.members == files)
        #expect(session.filePreviewSet?.index == 1)
        #expect(router.route(.next, from: .key, to: session))
        #expect(session.filePreviewSet?.current == files[2])
        #expect(router.route(.previous, from: .key, to: session))
        #expect(router.route(.previous, from: .key, to: session))
        #expect(session.filePreviewSet?.current == files[0])
    }
    func close() {
        window.close()
        try? FileManager.default.removeItem(at: base)
    }
    func waitUntil(_ condition: () -> Bool, fileID: String = #fileID, line: Int = #line) async throws {
        try await MadoAppTests.waitUntil(fileID: fileID, line: line, condition)
        #expect(condition(), "timed out")
    }
    static func button(_ identifier: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
        return view.subviews.lazy.compactMap { button(identifier, in: $0) }.first
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue150OpenGrantedFolderCancelRestoresFilePreviewSet() async throws {
    let scene = try await Issue150Scene()
    defer { scene.close() }
    try await scene.openFilePreviewSetAtMiddle()
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntilReading()
    #expect(scene.controller.session.filePreviewSet == nil, "the folder entry owns navigation while it reads")
    try await scene.cancelReading()
    scene.expectSetRestoredAtMiddle()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue150OpenRecentCancelRestoresFilePreviewSet() async throws {
    let scene = try await Issue150Scene()
    defer { scene.close() }
    let rootID = try await scene.services.files.grant(folder: scene.folder)
    try await scene.openFilePreviewSetAtMiddle()
    scene.controller.openRecent(RecentFolder(rootID: rootID, url: scene.folder, displayName: "Folder"))
    try await scene.waitUntilReading()
    #expect(scene.controller.session.filePreviewSet == nil)
    try await scene.cancelReading()
    scene.expectSetRestoredAtMiddle()
}
