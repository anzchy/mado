import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

/// Real enumeration with explicit attempt-scoped completion/failure, including cancellation drainage.
private actor ReadOwner454Scanner: FolderScanning {
    private let browser = FolderBrowser()
    private var attempts: [String: Int] = [:]
    private var active: Set<String> = []
    private var held: [String: CheckedContinuation<Bool, Never>] = [:]
    private func key(_ folder: URL, _ attempt: Int) -> String { "\(folder.standardizedFileURL.path)#\(attempt)" }
    func isHolding(_ folder: URL, attempt: Int) -> Bool { held[key(folder, attempt)] != nil }
    var allEnded: Bool { active.isEmpty }
    func release(_ folder: URL, attempt: Int, fail: Bool = false) {
        held.removeValue(forKey: key(folder, attempt))?.resume(returning: fail)
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
        if fail { throw CocoaError(.fileReadUnknown) }
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
    init() async throws {
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
        rootID = try await access.grant(folder: parent)
        let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let createdController = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: ReadOwner454Motion()))
        controller = createdController
        window = try #require(createdController.window)
        createdController.folderScanningOverride = scanner
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
        try await PicseeAppTests.waitUntil(description, between: { self.present() }, condition)
        present()
    }
    func expectCount(_ url: URL, _ count: Int?) throws {
        let folderRow = try #require(self.row(url))
        #expect(folderRow.countLabel.stringValue == (count.map(String.init) ?? ""))
        #expect(folderRow.countLabel.isHidden == (count == nil))
        let images = count.map { String(format: String(localized: "%lld images"), Int64($0)) }
        #expect(folderRow.accessibilityLabel() == (images.map { "\(url.lastPathComponent), \($0)" } ?? url.lastPathComponent))
        #expect(!window.isVisible)
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
        await scanner.releaseAll()
        window.close()
        try? await PicseeAppTests.waitUntil("read-owner scanner teardown") { await self.scanner.allEnded }
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
        await f.scanner.release(f.child, attempt: 1, fail: true)
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
        try #require(f.button("state.retry-folder")).performClick(nil)
        try await f.wait("held Retry child") { await f.scanner.isHolding(f.child, attempt: 2) }
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
