import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

private struct Footer506Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}
private actor Footer506Scanner: FolderScanning {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var held = false
    private(set) var finished = false
    func releaseLateBatch() { release?.resume(); release = nil }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        // The coordinator holds the root lease, as it does for FolderBrowser's
        // equivalent canonical-directory enumeration.
        let scanFolder = folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let entries = try FileManager.default.contentsOfDirectory(at: scanFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
            .map { FolderEntry(url: $0, root: root) }
        guard folder.lastPathComponent == "large" else { try await emit(entries); return }
        try await emit(Array(entries.prefix(2)))
        await withCheckedContinuation { release = $0; held = true }
        // Deliberately ignore cancellation: a filesystem adapter may already have queued a delivery.
        defer { finished = true }
        try await emit(Array(entries.dropFirst(2)))
    }
}
@MainActor private final class Footer506Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}
@MainActor private func footer506Find(_ id: String, _ root: NSView?) -> NSView? {
    guard let root else { return nil }
    if root.accessibilityIdentifier() == id { return root }
    return root.subviews.lazy.compactMap { footer506Find(id, $0) }.first
}
@Test(.timeLimit(.minutes(3)), arguments: [0, 3]) @MainActor
func issue506CancelledReadRestoresFooterAndSource(previousCount: Int) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("footer506-\(UUID())")
    defer { try? fm.removeItem(at: base) }
    let tree = base.appendingPathComponent("tree"), large = tree.appendingPathComponent("large")
    try fm.createDirectory(at: large, withIntermediateDirectories: true)
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: asset)
    for n in 0..<5 { try data.write(to: large.appendingPathComponent("\(n).png")) }
    for n in 0..<previousCount { try data.write(to: tree.appendingPathComponent("prior-\(n).png")) }
    let adapter = Footer506Bookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue506")
    let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Footer506Motion()))
    let scanner = Footer506Scanner()
    controller.folderScanningOverride = scanner
    let window = try #require(controller.window)
    defer { window.close() }
    controller.showWindow(nil)
    window.setContentSize(NSSize(width: 1280, height: 800))
    func wait(_ condition: () -> Bool) async throws {
        try await PicseeAppTests.waitUntil(between: { window.update() }, condition)
    }
    func count() throws -> String {
        try #require(footer506Find("grid.folder-count", window.contentView) as? NSTextField).stringValue
    }
    func expectRestoredSidebar() throws {
        let row = try #require(footer506Find("grid.sidebar.folder.tree", window.contentView) as? GridSidebarFolderButton)
        #expect(row.current)
        #expect(row.folderURL.standardizedFileURL.path == tree.standardizedFileURL.path)
        #expect(row.countLabel.stringValue == String(previousCount))
        #expect(!row.countLabel.isHiddenOrHasHiddenAncestor)
    }
    func waitForRestoredSidebar() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
            if let row = footer506Find("grid.sidebar.folder.tree", window.contentView) as? GridSidebarFolderButton,
               row.current, row.folderURL.standardizedFileURL.path == tree.standardizedFileURL.path,
               row.countLabel.stringValue == String(previousCount), !row.countLabel.isHiddenOrHasHiddenAncestor { return }
            if ContinuousClock.now >= deadline {
                throw ConditionWaitError(description: "restored sidebar count did not settle within 8 seconds")
            }
            window.update()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    controller.openGrantedFolder(tree)
    try await wait { controller.session.folderScan?.sourceSnapshot?.isComplete == true
        && controller.session.folderScan?.isScanning == false && (try? count()) == "\(previousCount) images" }
    let scan = try #require(controller.session.folderScan)
    let previous = try #require(scan.sourceSnapshot)
    #expect(previous.navigationEntries.count == previousCount)
    #expect(try count() == "\(previousCount) images")
    try await wait { footer506Find("grid.sidebar.folder.large", window.contentView) != nil }
    let child = try #require(footer506Find("grid.sidebar.folder.large", window.contentView) as? NSButton)
    child.performClick(nil)
    // Deliver the previous source's queued callback while the new folder entry awaits admission.
    // It must not complete the new entry or discard its restore point.
    controller.applyObservedGridSnapshot(previous)
    try await wait { scan.isReadingFolder && scan.sourceSnapshot?.navigationEntries.count == 2 }
    while !(await scanner.held) { await Task.yield() }
    // Drain the real partial-snapshot presentation synchronously, rather than racing its Observation task.
    let abandoned = try #require(scan.snapshot)
    controller.applyObservedGridSnapshot(abandoned)
    #expect(abandoned.isComplete == false)
    #expect(try count() == "Reading…")
    let cancel = try #require(footer506Find("state.cancel-folder", window.contentView) as? NSButton)
    cancel.performClick(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(scan.sourceSnapshot == previous)
    #expect(try count() == "\(previousCount) images")
    #expect(controller.session.mode == .browsing)
    try await waitForRestoredSidebar()
    try expectRestoredSidebar()
    // Insert a queued old presentation callback after rollback, then release the cancelled scanner's last batch.
    controller.applyObservedGridSnapshot(abandoned)
    #expect(scan.sourceSnapshot == previous)
    #expect(try count() == "\(previousCount) images")
    controller.applyObservedGridSnapshot(abandoned.appending([], isComplete: true))
    #expect(scan.sourceSnapshot == previous)
    #expect(try count() == "\(previousCount) images")
    await scanner.releaseLateBatch()
    // Await the adapter itself, not a duration chosen to hope the stale delivery has run.
    while !(await scanner.finished) { await Task.yield() }
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(scan.sourceSnapshot == previous)
    #expect(try count() == "\(previousCount) images")
    #expect(scan.isReadingFolder == false)
    try await waitForRestoredSidebar()
    try expectRestoredSidebar()
}

/// The snapshot identity and entry admission must agree even when lexical parent removal crosses a symlink.
@Test @MainActor func issue506SymlinkParentFolderCompletesNormally() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("symlink506-\(UUID())")
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual")
    let target = base.appendingPathComponent("target")
    let deep = target.appendingPathComponent("deep")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createDirectory(at: deep, withIntermediateDirectories: true)
    let canonical = target.appendingPathComponent("actual")
    try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: deep)
    let spelling = URL(fileURLWithPath: base.path + "/link/../actual/", isDirectory: true)
    let expected = spelling.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    #expect(expected.path == canonical.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path)
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try Data(contentsOf: asset).write(to: canonical.appendingPathComponent("one.png"))
    let adapter = Footer506Bookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue506-symlink")
    let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Footer506Motion()))
    controller.folderScanningOverride = Footer506Scanner()
    let window = try #require(controller.window)
    defer { window.close() }
    controller.openGrantedFolder(spelling)
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while controller.session.folderScan?.sourceSnapshot?.isComplete != true
        || controller.session.folderScan?.isScanning != false {
        if clock.now >= deadline {
            throw ConditionWaitError(description: "#507: symlink entry did not produce a completed source within 8 seconds")
        }
        window.update()
        try await Task.sleep(for: .milliseconds(5))
    }
    let source = try #require(controller.session.folderScan?.snapshot)
    controller.applyObservedGridSnapshot(source)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(source.version.folder == expected)
    #expect(try #require(footer506Find("grid.folder-count", window.contentView) as? NSTextField).stringValue == "1 images")
    #expect(controller.gridSearchAvailable)
}

/// Equivalent non-alias spellings must not leave the new entry stuck in Reading.
@Test(.timeLimit(.minutes(3))) @MainActor func issue506NormalizedFolderCompletesNormally() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("normalized506-\(UUID())")
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    let spelling = URL(fileURLWithPath: actual.path + "/../actual/", isDirectory: true)
    #expect(spelling.path != spelling.standardizedFileURL.path, "fixture retains the parent component")
    #expect(spelling.standardizedFileURL.path == actual.standardizedFileURL.path)
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try Data(contentsOf: asset).write(to: actual.appendingPathComponent("one.png"))
    let adapter = Footer506Bookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue506-normalized")
    let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Footer506Motion()))
    controller.folderScanningOverride = Footer506Scanner()
    let window = try #require(controller.window)
    defer { window.close() }
    controller.openGrantedFolder(spelling)
    try await PicseeAppTests.waitUntil(between: { window.update() }) {
        controller.session.folderScan?.sourceSnapshot?.isComplete == true
            && controller.session.folderScan?.isScanning == false
    }
    let source = try #require(controller.session.folderScan?.snapshot)
    controller.applyObservedGridSnapshot(source)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(source.version.folder.path == actual.resolvingSymlinksInPath().standardizedFileURL.path)
    #expect(try #require(footer506Find("grid.folder-count", window.contentView) as? NSTextField).stringValue == "1 images")
    #expect(controller.gridSearchAvailable)
}
