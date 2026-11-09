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
    private var recovered = false
    func recoverLocked() { recovered = true }
    func holdNextScan() { releaseScan = false }
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
        if recovered { return try await SystemSidebarFolderEnumerator().children(in: folder, root: root) }
        if folder.lastPathComponent == "Locked" {
            lockedListings += 1
            if denyListing { throw CocoaError(.fileReadNoPermission) }
        }
        return try await SystemSidebarFolderEnumerator().children(in: folder, root: root)
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        if recovered { return try await SystemSidebarFolderEnumerator().imageCount(in: folder, root: root) }
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
            if recovered {
                try await FolderBrowser().scan(in: folder, root: root, options: options, emit: emit)
                return
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
    let sidebarAccess: FileAccess
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
        sidebarAccess = access
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

@Test(.timeLimit(.minutes(3))) @MainActor func issue604RetryKeepsFailureTreeThenRestoresRealCount() async throws {
    let scene = try Issue604Scene(denyListing: false, holdScan: true)
    defer { scene.close() }
    try await withAsyncTeardown {
        try await scene.openParent()
        try #require(scene.row(scene.locked)).performClick(nil)
        try await scene.wait { await scene.reads.lockedScans == 1 }
        await scene.reads.release()
        try await scene.wait { scene.failed != nil }
        try await scene.settleFailureTree()
        try await scene.wait { scene.row(scene.readable)?.countLabel.stringValue == "2" }
        try scene.expectFailureTree()
        await scene.reads.holdNextScan()
        try #require(scene.failed).retryButton.performClick(nil)
        try await scene.wait { await scene.reads.lockedScans == 2 }
        #expect(scene.topology == ["Parent:0:false", "Locked:1:true", "Readable:1:false"])
        #expect(scene.row(scene.locked)?.countLabel.isHidden == true)
        #expect(scene.row(scene.readable)?.countLabel.stringValue == "2")
        await scene.reads.release()
        try await scene.wait { scene.failed != nil && scene.controller.session.folderScan?.isScanning == false }
        try scene.expectFailureTree()
        await scene.reads.holdNextScan()
        await scene.reads.recoverLocked()
        try #require(scene.failed).retryButton.performClick(nil)
        try await scene.wait { await scene.reads.lockedScans == 3 }
        #expect(scene.topology == ["Parent:0:false", "Locked:1:true", "Readable:1:false"])
        #expect(scene.row(scene.locked)?.countLabel.isHidden == true)
        await scene.reads.release()
        try await scene.wait { scene.controller.gridSearchAvailable && scene.row(scene.locked)?.countLabel.stringValue == "3" }
        #expect(scene.failed == nil)
        try await scene.wait { scene.topology == ["Parent:0:false", "Locked:1:true"] }
        #expect(scene.topology == ["Parent:0:false", "Locked:1:true"])
        #expect(scene.controller.session.folderScan?.sourceSnapshot?.navigationEntries.count == 3)
    } teardown: { await scene.reads.release() }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue604FailureSiblingCanOpen() async throws {
    let scene = try Issue604Scene()
    defer { scene.close() }
    try await scene.openParent()
    try #require(scene.row(scene.locked)).performClick(nil)
    try await scene.wait { scene.failed != nil }
    try await scene.settleFailureTree()
    try scene.expectFailureTree()
    try #require(scene.row(scene.readable)).performClick(nil)
    try await scene.wait { scene.controller.gridSearchAvailable && scene.row(scene.readable)?.countLabel.stringValue == "2" }
    #expect(scene.window.title == "Readable")
    #expect(scene.topology == ["Parent:0:false", "Readable:1:true", "Inner:2:false"])
    #expect(scene.controller.session.folderScan?.sourceSnapshot?.version.folder.standardizedFileURL.path == scene.readable.path)
    #expect(scene.controller.session.folderScan?.sourceSnapshot?.navigationEntries.count == 2)
    #expect(scene.failed == nil)
}

/// A filesystem result captured before a transition is deliberately allowed to return after cancellation.
/// The real loader/controller must discard it; the test does not cancel or replace generations itself.
private actor Issue604LateListing: SidebarFolderEnumerating {
    let folderName: String
    let fails: Bool
    let holdCount: Bool
    private var armed = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var holding = false
    private(set) var returned = false
    init(folderName: String, fails: Bool = false, holdCount: Bool = false) {
        self.folderName = folderName; self.fails = fails; self.holdCount = holdCount
    }
    func arm() { armed = true }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        let children = try await SystemSidebarFolderEnumerator().children(in: folder, root: root)
        if !holdCount && armed && folder.lastPathComponent == folderName {
            armed = false
            holding = true
            if !released { await withCheckedContinuation { waiter = $0 } }
            holding = false
            returned = true
            if fails { throw CocoaError(.fileReadNoPermission) }
        }
        return children
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        let count = try await SystemSidebarFolderEnumerator().imageCount(in: folder, root: root)
        if holdCount && armed && folder.lastPathComponent == folderName {
            armed = false
            holding = true
            if !released { await withCheckedContinuation { waiter = $0 } }
            holding = false
            returned = true
        }
        return count
    }
}

/// Observe release of the actual FileAccess leases, including the deliberately late operation.
private actor Issue604ObservedLeases: AccessLeasing {
    let access: FileAccess
    private var active: Set<UUID> = []
    var outstanding: Int { active.count }
    init(access: FileAccess) { self.access = access }
    func acquire(_ request: AccessRequest) async throws -> AccessLease {
        let lease = try await access.acquire(request)
        active.insert(lease.token)
        return lease
    }
    func release(_ lease: AccessLease) async {
        await access.release(lease)
        active.remove(lease.token)
    }
}

@MainActor private func issue604ExpectStableAfterRelease(_ scene: Issue604Scene,
    leases: Issue604ObservedLeases, topology: [String], count: String) async throws {
    try await scene.wait { await leases.outstanding == 0 }
    // FileAccess has released the old operation. Pump subsequent actor/run-loop work and assert
    // throughout, so a callback queued after the adapter's return cannot escape an immediate check.
    for _ in 0..<12 {
        try await Task.sleep(for: .milliseconds(5))
        scene.window.contentView?.layoutSubtreeIfNeeded()
        #expect(scene.topology == topology)
        #expect(scene.tree.rows.first(where: \.current)?.countLabel.stringValue == count)
    }
}

@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func issue604SameOpenLateSidebarSuccessCannotReplaceFailureTree(holdCount: Bool) async throws {
    let scene = try Issue604Scene(denyListing: false, holdScan: true)
    defer { scene.close() }
    let late = Issue604LateListing(folderName: "Locked", holdCount: holdCount)
    let leases = Issue604ObservedLeases(access: scene.sidebarAccess)
    try await withAsyncTeardown {
        try await scene.openParent()
        scene.controller.sidebarBrowserOverride = SidebarFolderBrowser(access: leases, enumerator: late)
        await late.arm()
        try #require(scene.row(scene.locked)).performClick(nil)
        try await scene.wait { await late.holding }
        await scene.reads.release()
        try await scene.wait { scene.failed != nil }
        try await scene.settleFailureTree()
        try scene.expectFailureTree()
        let before = scene.topology
        await late.release()
        try await scene.wait { await late.returned }
        try await issue604ExpectStableAfterRelease(scene, leases: leases, topology: before, count: "—")
        #expect(scene.topology == before)
        try scene.expectFailureTree()
    } teardown: { await late.release(); await scene.reads.release() }
}

@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func issue604LateOldResultsCannotRebuildNewTree(fails: Bool) async throws {
    let scene = try Issue604Scene(denyListing: false, holdScan: true)
    defer { scene.close() }
    let late = Issue604LateListing(folderName: "Parent", fails: fails)
    let leases = Issue604ObservedLeases(access: scene.sidebarAccess)
    try await withAsyncTeardown {
        try await scene.openParent()
        let rootID = try #require(scene.controller.session.folderScan?.sourceSnapshot?.version.rootID)
        scene.controller.sidebarBrowserOverride = SidebarFolderBrowser(access: leases, enumerator: late)
        await late.arm()
        try #require(scene.row(scene.locked)).performClick(nil)
        try await scene.wait { await scene.reads.lockedScans == 1 }
        await scene.reads.release()
        try await scene.wait { await late.holding }
        // Recovery's Parent enumeration is now held. A newer open owns the visible sidebar.
        scene.controller.browseRecoveredFolder(scene.readable, rootID: rootID)
        try await scene.wait { scene.controller.gridSearchAvailable && scene.row(scene.readable)?.countLabel.stringValue == "2" }
        let before = scene.topology
        await late.release()
        try await scene.wait { await late.returned }
        try await issue604ExpectStableAfterRelease(scene, leases: leases, topology: before, count: "2")
        #expect(scene.topology == before)
        #expect(scene.topology == ["Parent:0:false", "Readable:1:true", "Inner:2:false"])
        #expect(scene.row(scene.readable)?.countLabel.stringValue == "2")
        #expect(scene.failed == nil)
    } teardown: { await late.release(); await scene.reads.release() }
}

/// Hold whichever listing the reopened session requests, so a stale failure marker cannot race past the check.
private actor Issue604PendingListing: SidebarFolderEnumerating {
    let reads: Issue604Reads
    private var armed = true
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var holding = false
    init(reads: Issue604Reads) { self.reads = reads }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        if armed {
            armed = false
            holding = true
            if !released { await withCheckedContinuation { waiter = $0 } }
            holding = false
        }
        return try await reads.children(in: folder, root: root)
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        try await reads.imageCount(in: folder, root: root)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue604LeaveThenReopenSameFolderStartsNormalL0Fallback() async throws {
    let scene = try Issue604Scene(holdScan: true)
    defer { scene.close() }
    let listing = Issue604PendingListing(reads: scene.reads)
    try await withAsyncTeardown {
        try await scene.openParent()
        let rootID = try #require(scene.controller.session.folderScan?.sourceSnapshot?.version.rootID)
        let lockedURL = try #require(scene.row(scene.locked)).folderURL
        try #require(scene.row(scene.locked)).performClick(nil)
        try await scene.wait { await scene.reads.lockedScans == 1 }
        await scene.reads.release()
        try await scene.wait { scene.failed != nil }
        try await scene.settleFailureTree()
        try scene.expectFailureTree()
        let image = scene.base.appendingPathComponent("standalone.png")
        try Data(contentsOf: scene.parent.appendingPathComponent("0.png")).write(to: image)
        scene.controller.open(image, accessRequest: .fileGrant(image))
        try await scene.wait {
            scene.controller.hasImage && scene.controller.session.folderScan?.snapshot == nil &&
                scene.controller.session.folderScan?.isScanning != true
        }
        #expect(scene.failed == nil)
        await scene.reads.holdNextScan()
        scene.controller.sidebarBrowserOverride = SidebarFolderBrowser(access: scene.sidebarAccess, enumerator: listing)
        // Reuse the exact row URL, including its directory spelling, rather than a path-equivalent new URL.
        scene.controller.browseRecoveredFolder(lockedURL, rootID: rootID)
        // Synchronous fallback belongs to the new read, before any listing can repair the stale marker.
        #expect(scene.topology == ["Locked:0:true"])
        #expect(scene.failed == nil)
        #expect(scene.row(scene.locked)?.countLabel.isHidden == true)
        #expect(scene.row(scene.locked)?.countLabel.stringValue.isEmpty == true)
        try await scene.wait {
            let heldListing = await listing.holding
            let scans = await scene.reads.lockedScans
            return heldListing && scans == 2
        }
        #expect(scene.topology == ["Locked:0:true"])
        #expect(scene.controller.session.folderScan?.isReadingFolder == true)
        #expect(scene.failed == nil)
    } teardown: { await listing.release(); await scene.reads.release() }
}

/// Forward real reads and observe the next authoritative reload after a real filesystem write.
private actor Issue604WatchReads: SidebarFolderEnumerating {
    let reads: Issue604Reads
    private(set) var listings = 0
    private(set) var counts: [String: Int] = [:]
    init(reads: Issue604Reads) { self.reads = reads }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        listings += 1
        return try await reads.children(in: folder, root: root)
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        let value = try await reads.imageCount(in: folder, root: root)
        counts[folder.standardizedFileURL.path] = value
        return value
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue604RealWatchReloadKeepsFailedRootTree() async throws {
    let scene = try Issue604Scene()
    defer { scene.close() }
    let probe = Issue604WatchReads(reads: scene.reads)
    let leases = Issue604ObservedLeases(access: scene.sidebarAccess)
    scene.controller.sidebarBrowserOverride = SidebarFolderBrowser(access: leases, enumerator: probe)
    try await scene.openParent()
    try #require(scene.row(scene.locked)).performClick(nil)
    try await scene.wait { scene.failed != nil }
    try await scene.settleFailureTree()
    try await scene.wait { scene.row(scene.parent)?.countLabel.stringValue == "1" }
    try scene.expectFailureTree()
    try await scene.wait { await leases.outstanding == 0 }
    let beforeWrite = await probe.listings
    let image = try Data(contentsOf: scene.parent.appendingPathComponent("0.png"))
    try image.write(to: scene.parent.appendingPathComponent("watch-added.png"))
    // No reconcileAll or synthetic callback: production FSEventSource and WatchHub must deliver the write.
    try await scene.wait { await probe.listings > beforeWrite }
    try await scene.wait {
        scene.row(scene.parent)?.countLabel.stringValue == "2" || scene.topology == ["Locked:0:true"]
    }
    // Observe either the completed real count or the broken topology; a mutant fails assertions, not a timeout.
    try scene.expectFailureTree()
    #expect(scene.row(scene.parent)?.countLabel.stringValue == "2")
    #expect(await probe.counts[scene.parent.standardizedFileURL.path] == 2)
}
