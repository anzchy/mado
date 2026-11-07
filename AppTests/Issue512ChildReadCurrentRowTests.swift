import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

private struct Child512Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}

/// The parent completes normally; the child emits a partial batch, then waits for an explicit failure.
private actor Child512Scanner: FolderScanning {
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var held = false
    func failChild() { released = true; gate?.resume(); gate = nil }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
            .map { FolderEntry(url: $0, root: root) }
        try await emit(entries)
        guard folder.lastPathComponent == "large" else { return }
        await withCheckedContinuation { continuation in
            held = true
            if released { continuation.resume() } else { gate = continuation }
        }
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
    }
}

@MainActor private final class Child512Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}
@MainActor private func child512Find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool) -> T? {
    guard let view else { return nil }
    if let candidate = view as? T, matching(candidate) { return candidate }
    for child in view.subviews {
        if let found = child512Find(type, in: child, matching: matching) { return found }
    }
    return nil
}

/// #512 / FOLDER-01, FOLDER-05 / P2-02, P2-04: an old parent observation cannot own a child's read or failure.
@Test(.timeLimit(.minutes(3))) @MainActor func issue512ChildReadKeepsTitleCurrentRowAndFailureDash() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("child512-\(UUID())")
    let tree = base.appendingPathComponent("tree"), large = tree.appendingPathComponent("large")
    try fm.createDirectory(at: large, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    try data.write(to: tree.appendingPathComponent("parent.png"))
    try data.write(to: large.appendingPathComponent("child.png"))
    let adapter = Child512Bookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue512")
    let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Child512Motion()))
    let scanner = Child512Scanner()
    controller.folderScanningOverride = scanner
    let window = try #require(controller.window)
    defer { window.close() }
    controller.showWindow(nil)
    window.setContentSize(NSSize(width: 1280, height: 800))
    func row(_ url: URL) -> GridSidebarFolderButton? {
        child512Find(GridSidebarFolderButton.self, in: window.contentView) {
            $0.folderURL.standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
    func present() { window.update(); window.contentView?.layoutSubtreeIfNeeded() }
    func wait(_ condition: () async -> Bool) async throws {
        try await PicseeAppTests.waitUntil(between: { present() }, condition)
        present()
    }
    controller.openGrantedFolder(tree)
    try await wait { controller.session.folderScan?.sourceSnapshot?.isComplete == true
        && controller.session.folderScan?.isScanning == false && row(large) != nil }
    let scan = try #require(controller.session.folderScan)
    let previous = try #require(scan.snapshot)
    #expect(previous.version.folder.path == tree.path && previous.isComplete)
    #expect(window.title == "tree")
    #expect(row(tree)?.current == true)
    try await withAsyncTeardown {
        try #require(row(large)).performClick(nil)
        // Reproduce the queued old observation before the child's asynchronous admission starts (#454/#506).
        controller.applyObservedGridSnapshot(previous)
        present()
        #expect(window.title == "large", "queued parent observation must not replace the child's title")
        #expect(row(large)?.current == true, "queued parent observation must not select tree")
        try await wait { await scanner.held }
        try await wait { scan.isReadingFolder && scan.snapshot?.version.folder.path == large.path }
        let partial = try #require(scan.snapshot)
        #expect(!partial.isComplete)
        controller.applyObservedGridSnapshot(partial)
        present()
        #expect(window.title == "large", "child title while its read is held")
        #expect(row(large)?.current == true, "child current row while its read is held")
        #expect(row(tree)?.current != true)
        #expect(row(large)?.countLabel.stringValue != "—", "read has not failed yet")
        await scanner.failChild()
        try await wait { scan.failure != nil && !scan.isScanning
            && child512Find(ReadFailedStateView.self, in: window.contentView) { !$0.isHiddenOrHasHiddenAncestor } != nil }
        #expect(window.title == "large")
        #expect(row(large)?.current == true)
        let failedChild = try #require(row(large))
        #expect(failedChild.countLabel.stringValue == "—")
        #expect(!failedChild.countLabel.isHiddenOrHasHiddenAncestor)
        let parent = try #require(row(tree))
        #expect(!parent.current)
        #expect(parent.countLabel.stringValue != "—", "failure dash belongs to large, never tree")
    } teardown: {
        await scanner.failChild()
        // Await the coordinator as well as releasing the adapter, including on an early assertion/wait failure.
        if scan.isScanning {
            try? await PicseeAppTests.waitUntil(between: { present() }) { !scan.isScanning }
        }
    }
}
