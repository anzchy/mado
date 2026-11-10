import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// Real enumeration with explicit attempt-scoped completion/failure, including cancellation drainage.
private actor ReadOwner454Scanner: FolderScanning {
    private let browser = FolderBrowser()
    private var attempts: [String: Int] = [:]
    private var active: Set<String> = []
    private var held: [String: CheckedContinuation<Bool, Never>] = [:]
    private var errors: [String: FileAccessError] = [:]
    private func key(_ folder: URL, _ attempt: Int) -> String { "\(folder.standardizedFileURL.path)#\(attempt)" }
    func isHolding(_ folder: URL, attempt: Int) -> Bool { held[key(folder, attempt)] != nil }
    var allEnded: Bool { active.isEmpty }
    func release(_ folder: URL, attempt: Int, fail: Bool = false) {
        held.removeValue(forKey: key(folder, attempt))?.resume(returning: fail)
    }
    func fail(_ folder: URL, attempt: Int, error: FileAccessError) {
        errors[key(folder, attempt)] = error
        release(folder, attempt: attempt, fail: true)
    }
    func releaseAll() {
        let continuations = Array(held.values)
        held.removeAll()
        for continuation in continuations { continuation.resume(returning: false) }
    }
    private func cancelled(_ key: String) { held.removeValue(forKey: key)?.resume(returning: false) }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let path = folder.standardizedFileURL.path
        attempts[path, default: 0] += 1
        let key = key(folder, attempts[path]!)
        active.insert(key)
        defer { active.remove(key) }
        try await browser.scan(in: folder, root: root, options: options, emit: emit)
        let fail = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { held[key] = continuation }
            }
        } onCancel: { Task { await self.cancelled(key) } }
        try Task.checkCancellation()
        if fail, let error = errors.removeValue(forKey: key) { throw error }
        if fail { throw CocoaError(.fileReadUnknown) }
    }
}

/// Hold one real filesystem count independently of the main read's lifecycle.
private actor ReadOwner454SidebarCounter: SidebarFolderEnumerating {
    private let system = SystemSidebarFolderEnumerator()
    private var armed: [URL: UUID] = [:]
    private var armedRows: [URL: UUID] = [:]
    private var captured: [UUID: Int] = [:]
    private var waits: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var rowWaits: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<UUID> = []
    private var releasingAll = false
    private var active = 0
    var allEnded: Bool { active == 0 }
    func arm(_ folder: URL) -> UUID {
        let id = UUID()
        armed[folder.standardizedFileURL] = id
        return id
    }
    func isHolding(_ id: UUID) -> Bool { waits[id] != nil }
    func armRows(_ folder: URL) -> UUID {
        let id = UUID()
        armedRows[folder.standardizedFileURL] = id
        return id
    }
    func capturedCount(_ id: UUID) -> Int? { captured[id] }
    func release(_ id: UUID) {
        released.insert(id)
        waits.removeValue(forKey: id)?.resume()
        rowWaits.removeValue(forKey: id)?.resume()
    }
    func releaseAll() {
        releasingAll = true
        let pending = Array(waits.values)
        waits.removeAll()
        for continuation in pending { continuation.resume() }
        let pendingRows = Array(rowWaits.values)
        rowWaits.removeAll()
        for continuation in pendingRows { continuation.resume() }
    }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        active += 1
        defer { active -= 1 }
        if let id = armedRows.removeValue(forKey: folder.standardizedFileURL) {
            let children = try await system.children(in: folder, root: root)
            if !releasingAll && !released.contains(id) {
                await withCheckedContinuation { rowWaits[id] = $0 }
            }
            try Task.checkCancellation()
            return children
        }
        return try await system.children(in: folder, root: root)
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        active += 1
        defer { active -= 1 }
        let count = try await system.imageCount(in: folder, root: root)
        if let id = armed.removeValue(forKey: folder.standardizedFileURL) {
            captured[id] = count
            if !releasingAll && !released.contains(id) {
                await withCheckedContinuation { waits[id] = $0 }
            }
        }
        try Task.checkCancellation()
        return count
    }
}

@MainActor private final class ReadOwner454Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func readOwner454Find<T: NSView>(_ type: T.Type, in view: NSView?,
    matching: (T) -> Bool) -> T? {
    guard let view else { return nil }
    if let found = view as? T, matching(found) { return found }
    for child in view.subviews {
        if let found = readOwner454Find(type, in: child, matching: matching) { return found }
    }
    return nil
}

@MainActor private final class ReadOwner454Fixture {
    let base: URL, parent: URL, child: URL, grandchild: URL
    let rootID: AccessRootID
    let controller: CanvasWindowController
    let scanner = ReadOwner454Scanner()
    let window: NSWindow
    private let sidebarCounter: ReadOwner454SidebarCounter?
    private var accessForSidebar: FileAccess?
    private var failureRowsCounter: ReadOwner454SidebarCounter?
    init(sidebarCounter: ReadOwner454SidebarCounter? = nil) async throws {
        self.sidebarCounter = sidebarCounter
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("readOwner454-\(UUID())")
        parent = base.appendingPathComponent("Parent")
        child = parent.appendingPathComponent("Child")
        grandchild = child.appendingPathComponent("Grandchild")
        try fm.createDirectory(at: grandchild, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let png = try Data(contentsOf: fixture)
        for i in 0..<2 { try png.write(to: parent.appendingPathComponent("parent-\(i).png")) }
        for i in 0..<3 { try png.write(to: child.appendingPathComponent("child-\(i).png")) }
        try png.write(to: grandchild.appendingPathComponent("grandchild.png"))
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "readOwner454")
        accessForSidebar = access
        rootID = try await access.grant(folder: parent)
        let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let createdController = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: ReadOwner454Motion()))
        controller = createdController
        window = try #require(createdController.window)
        createdController.folderScanningOverride = scanner
        if let sidebarCounter {
            createdController.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: sidebarCounter)
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
    }
    var shell: GridShellView? { readOwner454Find(GridShellView.self, in: window.contentView) { _ in true } }
    func present() { window.update(); window.contentView?.layoutSubtreeIfNeeded() }
    func row(_ url: URL) -> GridSidebarFolderButton? {
        readOwner454Find(GridSidebarFolderButton.self, in: window.contentView) {
            $0.folderURL.standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
    func button(_ identifier: String) -> NSButton? {
        readOwner454Find(NSButton.self, in: window.contentView) {
            $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor
        }
    }
    func field(_ identifier: String) -> NSTextField? {
        readOwner454Find(NSTextField.self, in: window.contentView) { $0.accessibilityIdentifier() == identifier }
    }
    func wait(_ description: String, _ condition: () async -> Bool) async throws {
        try await MadoAppTests.waitUntil(description, between: { self.present() }, condition)
        present()
    }
    func retryReady(attempt: Int) async -> Bool {
        let holding = await scanner.isHolding(child, attempt: attempt)
        guard row(parent)?.countLabel.stringValue == "2" else { return false }
        return holding
    }
    func plainFailureReady() -> Bool {
        let ready = controller.session.folderScan?.failure != nil && button("state.retry-folder") != nil
            && row(child)?.countLabel.stringValue == "—"
        guard row(parent)?.countLabel.stringValue == "2", row(grandchild)?.countLabel.stringValue == "1" else { return false }
        return ready
    }
    func holdFailureRows() async throws -> UUID {
        let access = try #require(accessForSidebar)
        let counter = ReadOwner454SidebarCounter()
        failureRowsCounter = counter
        let id = await counter.armRows(parent)
        controller.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: counter)
        return id
    }
    func releaseFailureRows(_ id: UUID) async {
        await failureRowsCounter?.release(id)
    }
    func waitForSettledFailureRows() async throws {
        try await wait("settled failed-read parent projection and counts") {
            let countsEnded = await self.failureRowsCounter?.allEnded ?? true
            return countsEnded && self.controller.session.folderScan?.failure != nil
                && self.button("state.retry-folder") != nil
                && self.row(self.child)?.countLabel.stringValue == "—"
                && self.row(self.parent)?.countLabel.stringValue == "2"
                && self.row(self.grandchild) == nil
        }
        #expect(!plainFailureReady())
    }
    func expectCount(_ url: URL, _ count: Int?, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let folderRow = try #require(self.row(url))
        #expect(folderRow.countLabel.stringValue == (count.map(String.init) ?? ""), sourceLocation: sourceLocation)
        #expect(folderRow.countLabel.isHidden == (count == nil), sourceLocation: sourceLocation)
        let images = count.map { String(format: String(localized: "%lld images"), Int64($0)) }
        #expect(folderRow.accessibilityLabel() == (images.map { "\(url.lastPathComponent), \($0)" } ?? url.lastPathComponent),
                sourceLocation: sourceLocation)
        #expect(!window.isVisible, sourceLocation: sourceLocation)
    }
    func beginParent() async throws -> FolderSnapshot {
        #expect(!window.isVisible)
        controller.browseRecoveredFolder(parent, rootID: rootID)
        try await wait("parent Reading and independent child count") {
            await self.scanner.isHolding(self.parent, attempt: 1)
                && self.row(self.child)?.countLabel.stringValue == "3"
                && self.controller.session.folderScan?.isReadingFolder == true
        }
        try expectCount(parent, nil)
        try expectCount(child, 3)
        #expect(shell?.readingFolderURL?.standardizedFileURL.path == parent.path)
        await scanner.release(parent, attempt: 1)
        try await wait("parent complete and authoritative sidebar recount") {
            self.controller.session.folderScan?.sourceSnapshot?.isComplete == true
                && self.controller.session.folderScan?.isScanning == false
                && self.row(self.parent)?.countLabel.stringValue == "2"
                && self.row(self.child)?.countLabel.stringValue == "3"
        }
        try expectCount(parent, 2)
        #expect(shell?.readingFolderURL == nil)
        return try #require(controller.session.folderScan?.snapshot)
    }
    func beginChild(replaying previous: FolderSnapshot) async throws {
        try #require(row(child)).performClick(nil)
        controller.applyObservedGridSnapshot(previous)
        #expect(window.title == child.lastPathComponent)
        #expect(row(child)?.current == true)
        try await wait("child Reading with both non-target counts freshly delivered") {
            await self.scanner.isHolding(self.child, attempt: 1)
                && self.row(self.parent)?.countLabel.stringValue == "2"
                && self.row(self.grandchild)?.countLabel.stringValue == "1"
                && self.controller.session.folderScan?.isReadingFolder == true
        }
        try expectCount(child, nil)
        try expectCount(parent, 2)
        try expectCount(grandchild, 1)
        #expect(shell?.readingFolderURL?.standardizedFileURL.path == child.path)
        #expect(field("grid.folder-count")?.stringValue == String(localized: "Reading…"))
        #expect(controller.session.folderScan?.sourceSnapshot?.version.folder.path == child.path)
        #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == false)
        #expect(window.title == child.lastPathComponent)
        #expect(row(child)?.current == true)
    }
    func close() async {
        await failureRowsCounter?.releaseAll()
        await sidebarCounter?.releaseAll()
        await scanner.releaseAll()
        window.close()
        try? await MadoAppTests.waitUntil("read-owner scanner and sidebar teardown") {
            let countsEnded = await self.sidebarCounter?.allEnded ?? true
            let scansEnded = await self.scanner.allEnded
            let failureRowsEnded = await self.failureRowsCounter?.allEnded ?? true
            guard failureRowsEnded else { return false }
            return countsEnded && scansEnded
        }
        try? FileManager.default.removeItem(at: base)
    }
}

/// S5: real child navigation owns the count mask through an old parent replay and cancellation.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454ReadOwnerChildCancelIgnoresOldParentAndReleasesMask() async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        try #require(f.button("state.cancel-folder")).performClick(nil)
        try await f.wait("cancel child restores complete parent and drains abandoned scan") {
            await f.scanner.allEnded && f.controller.session.folderScan?.isReadingFolder == false
                && f.controller.session.folderScan?.sourceSnapshot?.version.folder.path == f.parent.path
                && f.controller.session.folderScan?.sourceSnapshot?.isComplete == true
                && f.row(f.parent)?.countLabel.stringValue == "2"
                && f.row(f.child)?.countLabel.stringValue == "3"
        }
        #expect(f.shell?.readingFolderURL == nil)
        #expect(f.window.title == f.parent.lastPathComponent)
        #expect(f.row(f.parent)?.current == true)
        try f.expectCount(f.parent, 2)
        try f.expectCount(f.child, 3)
        await f.scanner.release(f.child, attempt: 1)
        f.present()
        #expect(f.shell?.readingFolderURL == nil)
        try f.expectCount(f.parent, 2)
        try f.expectCount(f.child, 3)
    } teardown: { await f.close() }
}

/// S5: plain 24F and reachable cancel-Retry restore clear the mask; Retry rebinds the same folder.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454ReadOwnerFailureRetryCancelAndCompletionUseActualFolder() async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        let failureRows = try await f.holdFailureRows()
        await f.scanner.release(f.child, attempt: 1, fail: true)
        try await f.wait("plain failure assertion boundary") { f.plainFailureReady() }
        try await f.wait("plain child 24F") {
            f.controller.session.folderScan?.failure != nil && f.button("state.retry-folder") != nil
                && f.row(f.child)?.countLabel.stringValue == "—"
        }
        #expect(f.shell?.readingFolderURL == nil)
        #expect(f.row(f.child)?.countLabel.isHidden == false)
        #expect(f.row(f.child)?.accessibilityLabel() == "Child, \(String(localized: "Read incomplete"))")
        #expect(f.field("grid.folder-count")?.stringValue == String(localized: "Read incomplete"))
        try f.expectCount(f.parent, 2)
        try f.expectCount(f.grandchild, 1)
        await f.releaseFailureRows(failureRows)
        try await f.waitForSettledFailureRows()
        try #require(f.button("state.retry-folder")).performClick(nil)
        try await f.wait("held Retry child") { await f.retryReady(attempt: 2) }
        try f.expectCount(f.child, nil)
        try f.expectCount(f.parent, 2)
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
        try #require(f.button("state.cancel-folder")).performClick(nil)
        try await f.wait("cancel Retry returns to failed child") {
            await f.scanner.allEnded && f.controller.session.folderScan?.failure != nil
                && f.button("state.retry-folder") != nil && f.row(f.child)?.countLabel.stringValue == "—"
        }
        #expect(f.shell?.readingFolderURL == nil)
        #expect(f.controller.session.folderScan?.isReadingFolder == false)
        #expect(f.row(f.child)?.accessibilityLabel() == "Child, \(String(localized: "Read incomplete"))")
        try await f.wait("cancel Retry parent recount delivered") { f.row(f.parent)?.countLabel.stringValue == "2" }
        try f.expectCount(f.parent, 2)
        try #require(f.button("state.retry-folder")).performClick(nil)
        try await f.wait("second Retry child held") { await f.scanner.isHolding(f.child, attempt: 3) }
        try f.expectCount(f.child, nil)
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
        await f.scanner.release(f.child, attempt: 3)
        try await f.wait("Retry completes child with final sidebar count") {
            f.controller.session.folderScan?.isReadingFolder == false
                && f.controller.session.folderScan?.sourceSnapshot?.isComplete == true
                && f.controller.session.folderScan?.isScanning == false
                && f.row(f.child)?.countLabel.stringValue == "3"
                && f.row(f.parent)?.countLabel.stringValue == "2"
                && f.row(f.grandchild)?.countLabel.stringValue == "1"
        }
        #expect(f.shell?.readingFolderURL == nil)
        #expect(f.window.title == f.child.lastPathComponent)
        try f.expectCount(f.child, 3)
        try f.expectCount(f.parent, 2)
        try f.expectCount(f.grandchild, 1)
    } teardown: { await f.close() }
}

/// S5: a held Retry is not a readiness barrier for its independently recounted parent row.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454RetryReadinessWaitsForParentRecount() async throws {
    let counter = ReadOwner454SidebarCounter()
    let f = try await ReadOwner454Fixture(sidebarCounter: counter)
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        try await f.wait("child sidebar counts drained before arming failed-read recount") { await counter.allEnded }
        let parentBeforeFailure = try #require(f.row(f.parent))
        try f.expectCount(f.parent, 2)
        let parentCount = await counter.arm(f.parent)
        await f.scanner.release(f.child, attempt: 1, fail: true)
        try await f.wait("failed-read replacement parent row waits for its real count") {
            let countHeld = await counter.isHolding(parentCount)
            return countHeld && f.controller.session.folderScan?.failure != nil
                && f.button("state.retry-folder") != nil
                && f.row(f.child)?.countLabel.stringValue == "—"
                && f.row(f.parent) != nil && f.row(f.parent) !== parentBeforeFailure
                && f.row(f.parent)?.countLabel.stringValue == ""
                && f.row(f.grandchild) == nil
        }
        let failedParentRow = try #require(f.row(f.parent))
        #expect(f.row(f.grandchild) == nil)
        #expect(await counter.capturedCount(parentCount) == 2)
        try f.expectCount(f.parent, nil)
        let plainReadyBeforeCount = f.plainFailureReady()
        #expect(!plainReadyBeforeCount)
        if plainReadyBeforeCount { try f.expectCount(f.parent, 2) }
        try #require(f.button("state.retry-folder")).performClick(nil)
        try await f.wait("Retry scan held while failed-read parent recount remains pending") {
            let countHeld = await counter.isHolding(parentCount)
            let scanHeld = await f.scanner.isHolding(f.child, attempt: 2)
            return countHeld && scanHeld && f.controller.session.folderScan?.isReadingFolder == true
                && f.row(f.parent) === failedParentRow
                && f.row(f.parent)?.countLabel.stringValue == ""
        }
        #expect(await counter.capturedCount(parentCount) == 2)
        try f.expectCount(f.parent, nil)
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
        let readyBeforeCount = await f.retryReady(attempt: 2)
        #expect(!readyBeforeCount)
        if readyBeforeCount { try f.expectCount(f.parent, 2) }

        await counter.release(parentCount)
        try await f.wait("Retry readiness follows delivered parent count") { await f.retryReady(attempt: 2) }
        try f.expectCount(f.parent, 2)
        try f.expectCount(f.child, nil)
        #expect(f.row(f.grandchild) == nil)
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
    } teardown: { await f.close() }
}

/// #597: model the stale openFolder catch resuming after Retry has cleared the prior failure.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue597StaleReadFailureDoesNotPromptDuringRetry() async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        var grantRequests: [URL] = []
        f.controller.folderGrantPromptOverride = { folder, _ in grantRequests.append(folder) }
        #expect(f.controller.session.folderScan?.failure == nil)
        #expect(f.controller.session.folderScan?.isReadingFolder == true)
        f.controller.handleFolderOpenFailure(CocoaError(.fileReadUnknown), folder: f.child, scanStarted: true)
        #expect(grantRequests.isEmpty)
        #expect(f.window.attachedSheet == nil)
        #expect(f.controller.session.folderScan?.isReadingFolder == true)
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
        await f.scanner.release(f.child, attempt: 1, fail: true)
        try await f.wait("597 child Read incomplete with Retry") {
            f.controller.session.folderScan?.failure != nil && f.button("state.retry-folder") != nil
                && f.row(f.child)?.countLabel.stringValue == "—"
        }
        f.controller.handleFolderOpenFailure(CocoaError(.fileReadUnknown), folder: f.child, scanStarted: true)
        #expect(grantRequests.isEmpty)
        #expect(f.window.attachedSheet == nil)
        #expect(!f.window.isVisible)
        #expect(f.field("grid.folder-count")?.stringValue == String(localized: "Read incomplete"))
        try #require(f.button("state.retry-folder")).performClick(nil)
        try await f.wait("597 Retry reads same child") { await f.scanner.isHolding(f.child, attempt: 2) }
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
        await f.scanner.release(f.child, attempt: 2)
        try await f.wait("597 Retry completes") {
            f.controller.session.folderScan?.sourceSnapshot?.isComplete == true
                && f.controller.session.folderScan?.isScanning == false
                && f.row(f.child)?.countLabel.stringValue == "3"
        }
        #expect(grantRequests.isEmpty)
        #expect(f.window.attachedSheet == nil)
    } teardown: { await f.close() }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue597PreScanFailureStillRestoresAndOffersFolderAccess() async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        var grantRequests: [URL] = []
        f.controller.folderGrantPromptOverride = { folder, _ in grantRequests.append(folder) }
        f.controller.handleFolderOpenFailure(CocoaError(.fileReadUnknown), folder: f.child, scanStarted: false)
        #expect(grantRequests == [f.child])
        #expect(f.window.attachedSheet == nil)
        #expect(f.window.title == f.parent.lastPathComponent)
        #expect(f.controller.session.folderScan?.sourceSnapshot?.version.folder.standardizedFileURL.path == f.parent.path)
        #expect(f.controller.session.folderScan?.sourceSnapshot?.isComplete == true)
        #expect(f.controller.session.folderScan?.isReadingFolder == false)
    } teardown: { await f.close() }
}

/// A real started child read with a readable root belongs to 24F-A, even for FileAccessError.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue597StartedChildAccessErrorShowsReadFailedWithoutGrant() async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        var grantRequests: [URL] = []
        f.controller.folderGrantPromptOverride = { folder, _ in grantRequests.append(folder) }
        await f.scanner.fail(f.child, attempt: 1, error: .invalidFolder)
        try await f.wait("597 child access error is Read incomplete") {
            f.controller.session.folderScan?.failure != nil && f.button("state.retry-folder") != nil
                && f.controller.session.folderScan?.isScanning == false
        }
        // Let the real openFolder awaiter resume after the coordinator has published its result.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)); f.present() }
        #expect(grantRequests.isEmpty)
        #expect(f.window.attachedSheet == nil)
        #expect(!f.window.isVisible)
        #expect(f.controller.session.folderScan?.failure as? FileAccessError == .invalidFolder)
        #expect(f.field("grid.folder-count")?.stringValue == String(localized: "Read incomplete"))
        #expect(f.row(f.child)?.countLabel.stringValue == "—")
        #expect(readOwner454Find(LostAccessStateView.self, in: f.window.contentView) { !$0.isHiddenOrHasHiddenAncestor } == nil)
        try #require(f.button("state.retry-folder")).performClick(nil)
        try await f.wait("597 access-error Retry reads child") { await f.scanner.isHolding(f.child, attempt: 2) }
        #expect(f.shell?.readingFolderURL?.standardizedFileURL.path == f.child.path)
        await f.scanner.release(f.child, attempt: 2)
        try await f.wait("597 access-error Retry completes child") {
            f.controller.session.folderScan?.sourceSnapshot?.isComplete == true
                && f.controller.session.folderScan?.isScanning == false
                && f.row(f.child)?.countLabel.stringValue == "3"
        }
        #expect(grantRequests.isEmpty)
        #expect(f.window.attachedSheet == nil)
    } teardown: { await f.close() }
}

/// The same real root loss presents page 26 for either an access error or a Cocoa read error.
@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func issue597LostRootDuringStartedChildReadShowsLostAccessWithoutSheet(accessError: Bool) async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        var grantRequests: [URL] = []
        f.controller.folderGrantPromptOverride = { folder, _ in grantRequests.append(folder) }
        try FileManager.default.removeItem(at: f.parent)
        if accessError { await f.scanner.fail(f.child, attempt: 1, error: .invalidFolder) }
        else { await f.scanner.release(f.child, attempt: 1, fail: true) }
        try await f.wait("597 removed root is Lost Access") {
            readOwner454Find(LostAccessStateView.self, in: f.window.contentView) { !$0.isHiddenOrHasHiddenAncestor } != nil
                && f.controller.session.folderScan?.isScanning != true
        }
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)); f.present() }
        #expect(grantRequests.isEmpty)
        #expect(f.window.attachedSheet == nil)
        #expect(!f.window.isVisible)
        #expect(f.button("state.retry-folder") == nil)
        #expect(f.controller.session.folderScan?.failure == nil)
        #expect(readOwner454Find(LostAccessStateView.self, in: f.window.contentView) { !$0.isHiddenOrHasHiddenAncestor } != nil)
    } teardown: { await f.close() }
}

@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func issue597CorruptStoreStillShowsAccessError(scanStarted: Bool) async throws {
    let f = try await ReadOwner454Fixture()
    try await withAsyncTeardown {
        let previous = try await f.beginParent()
        try await f.beginChild(replaying: previous)
        var grantRequests: [URL] = []
        f.controller.folderGrantPromptOverride = { folder, _ in grantRequests.append(folder) }
        f.controller.handleFolderOpenFailure(FileAccessError.corruptStore, folder: f.child, scanStarted: scanStarted)
        let sheet = try #require(f.window.attachedSheet)
        let message = readOwner454Find(NSTextField.self, in: sheet.contentView) {
            $0.stringValue == String(localized: "Folder Access Failed")
        }
        #expect(message != nil)
        #expect(grantRequests.isEmpty)
        #expect(f.window.title == (scanStarted ? f.child : f.parent).lastPathComponent)
    } teardown: {
        if let sheet = f.window.attachedSheet { f.window.endSheet(sheet); sheet.orderOut(nil) }
        await f.close()
    }
}
