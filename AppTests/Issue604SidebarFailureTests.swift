import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private struct Issue604Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}

/// Only the filesystem boundary is controlled; successful reads use the production adapters.
private actor Issue604Reads: SidebarFolderEnumerating, FolderScanning {
    let denyListing: Bool
    let denyScan: Bool
    let holdScan: Bool
    private var releaseScan = false
    private var scanWaiter: CheckedContinuation<Void, Never>?
    private(set) var lockedListings = 0
    private(set) var lockedCounts = 0
    private(set) var lockedScans = 0
    init(denyListing: Bool = true, denyScan: Bool = true, holdScan: Bool = false) {
        self.denyListing = denyListing; self.denyScan = denyScan; self.holdScan = holdScan
    }
    func release() { releaseScan = true; scanWaiter?.resume(); scanWaiter = nil }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        if folder.lastPathComponent == "Locked" {
            lockedListings += 1
            if denyListing { throw CocoaError(.fileReadNoPermission) }
        }
        return try await SystemSidebarFolderEnumerator().children(in: folder, root: root)
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        if folder.lastPathComponent == "Locked" {
            lockedCounts += 1
            if denyListing { throw CocoaError(.fileReadNoPermission) }
        }
        return try await SystemSidebarFolderEnumerator().imageCount(in: folder, root: root)
    }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        if folder.lastPathComponent == "Locked" {
            lockedScans += 1
            if denyScan {
                try await emit([FolderEntry(url: folder.appendingPathComponent("0.png"), root: root)])
            }
            if holdScan && !releaseScan {
                await withCheckedContinuation { scanWaiter = $0 }
            }
            if denyScan { throw CocoaError(.fileReadNoPermission) }
        }
        try await FolderBrowser().scan(in: folder, root: root, options: options, emit: emit)
    }
}

@MainActor private final class Issue604Motion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue604Find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    if let value = view as? T { return value }
    for child in view.subviews { if let value = issue604Find(type, in: child) { return value } }
    return nil
}

@MainActor private final class Issue604Scene {
    let base: URL, parent: URL, locked: URL, readable: URL
    let controller: CanvasWindowController
    let window: NSWindow
    let reads: Issue604Reads
    init(denyListing: Bool = true, denyScan: Bool = true, holdScan: Bool = false) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("issue604-\(UUID())")
        parent = base.appendingPathComponent("Parent")
        locked = parent.appendingPathComponent("Locked")
        readable = parent.appendingPathComponent("Readable")
        for folder in [locked, readable.appendingPathComponent("Inner")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: fixture)
        for (folder, count) in [(parent, 1), (locked, 3), (readable, 2)] {
            for index in 0..<count { try data.write(to: folder.appendingPathComponent("\(index).png")) }
        }
        let adapter = Issue604Bookmarks()
        let access = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue604")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue604Motion()))
        window = try #require(controller.window)
        reads = Issue604Reads(denyListing: denyListing, denyScan: denyScan, holdScan: holdScan)
        controller.folderScanningOverride = reads
        controller.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: reads)
    }
    func close() { window.close(); try? FileManager.default.removeItem(at: base) }
    var tree: GridSidebarTreeView { issue604Find(GridSidebarTreeView.self, in: window.contentView)! }
    var failed: ReadFailedStateView? {
        guard let page = issue604Find(ReadFailedStateView.self, in: window.contentView), !page.isHiddenOrHasHiddenAncestor else { return nil }
        return page
    }
    var topology: [String] { tree.rows.map { "\($0.folderURL.lastPathComponent):\($0.depth):\($0.current)" } }
    func row(_ url: URL) -> GridSidebarFolderButton? {
        tree.rows.first { $0.folderURL.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    func wait(_ condition: () async -> Bool) async throws {
        try await MadoAppTests.waitUntil(between: { self.window.contentView?.layoutSubtreeIfNeeded() }, condition)
    }
    func openParent() async throws {
        controller.openGrantedFolder(parent)
        try await wait { self.controller.gridSearchAvailable && self.row(self.readable)?.countLabel.stringValue == "2" }
    }
    func settleFailureTree() async throws {
        // Bound the missing-row regression without waiting for a callback the broken code never emits.
        // The exact topology assertions below still report the actual collapsed rows on RED.
        let deadline = ContinuousClock.now + .seconds(2)
        while topology != ["Parent:0:false", "Locked:1:true", "Readable:1:false"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func expectFailureTree() throws {
        #expect(topology == ["Parent:0:false", "Locked:1:true", "Readable:1:false"])
        #expect(tree.rows.filter(\.current).count == 1)
        let current = try #require(row(locked))
        #expect(current.countLabel.stringValue == "—")
        #expect(!current.countLabel.isHidden)
        #expect(row(parent)?.countLabel.stringValue != "—")
        #expect(row(readable)?.countLabel.stringValue != "—")
        #expect(failed != nil)
        #expect(window.attachedSheet == nil)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue604FailedChildKeepsParentAndReadableSibling() async throws {
    let scene = try Issue604Scene()
    defer { scene.close() }
    try await scene.openParent()
    try #require(scene.row(scene.locked)).performClick(nil)
    try await scene.wait {
        let listings = await scene.reads.lockedListings
        return scene.failed != nil && listings > 0
    }
    // A settled failure must show the root tree, rather than Locked alone at L0.
    try await scene.settleFailureTree()
    try scene.expectFailureTree()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue604ScanOnlyFailureKeepsRootDespiteSuccessfulSidebarLoad() async throws {
    let scene = try Issue604Scene(denyListing: false, holdScan: true)
    defer { scene.close() }
    try await withAsyncTeardown {
        try await scene.openParent()
        let countsBeforeChild = await scene.reads.lockedCounts
        try #require(scene.row(scene.locked)).performClick(nil)
        try await scene.wait { await scene.reads.lockedCounts > 0 }
        try await scene.wait { await scene.reads.lockedCounts > countsBeforeChild }
        try await scene.wait { scene.topology == ["Parent:0:false", "Locked:1:true"] }
        #expect(scene.topology == ["Parent:0:false", "Locked:1:true"])
        #expect(scene.controller.session.folderScan?.snapshot?.isComplete != true)
        await scene.reads.release()
        try await scene.wait { scene.failed != nil }
        try await scene.settleFailureTree()
    try scene.expectFailureTree()
    } teardown: { await scene.reads.release() }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue604ReadableChildRetainsExistingProjection() async throws {
    let scene = try Issue604Scene(denyListing: false, denyScan: false)
    defer { scene.close() }
    try await scene.openParent()
    try #require(scene.row(scene.readable)).performClick(nil)
    try await scene.wait { scene.controller.gridSearchAvailable && scene.row(scene.readable)?.countLabel.stringValue == "2" }
    #expect(scene.topology == ["Parent:0:false", "Readable:1:true", "Inner:2:false"])
    #expect(scene.row(scene.locked) == nil)
    #expect(scene.failed == nil)
}
