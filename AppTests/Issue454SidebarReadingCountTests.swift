import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// Delays only completion: real FolderBrowser still enumerates and emits every entry.
private final class Sidebar454HeldScanner: FolderScanning, @unchecked Sendable {
    private let browser = FolderBrowser()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var holding = false
    private var active = 0
    var isHolding: Bool { lock.withLock { holding } }
    var allEnded: Bool { lock.withLock { active == 0 } }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            holding = false
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }

    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        lock.withLock { active += 1 }
        defer { lock.withLock { active -= 1 } }
        try await browser.scan(in: folder, root: root, options: options, emit: emit)
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                let resumeNow = lock.withLock { () -> Bool in
                    if released || Task.isCancelled { return true }
                    continuation = pending
                    holding = true
                    return false
                }
                if resumeNow { pending.resume() }
            }
        } onCancel: { self.release() }
        try Task.checkCancellation()
    }
}

@MainActor private final class Sidebar454Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func sidebar454Find<T: NSView>(_ type: T.Type, in view: NSView?,
                                                matching: (T) -> Bool) -> T? {
    guard let view else { return nil }
    if let candidate = view as? T, matching(candidate) { return candidate }
    for child in view.subviews {
        if let found = sidebar454Find(type, in: child, matching: matching) { return found }
    }
    return nil
}

/// #454 / FOLDER-01, FOLDER-05 / P2-02, P2-04: page 24 leaves the reading row's count blank.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454SidebarCountStaysBlankWhileMainScanIsReading() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("sidebar454-\(UUID())")
    let folder = base.appendingPathComponent("Reading"), child = folder.appendingPathComponent("Child")
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let png = try Data(contentsOf: fixture)
    for index in 0..<3 { try png.write(to: folder.appendingPathComponent("image-\(index).png")) }
    try png.write(to: child.appendingPathComponent("child.png"))
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue454-repro")
    let rootID = try await access.grant(folder: folder)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Sidebar454Motion()))
    let scanner = Sidebar454HeldScanner()
    controller.folderScanningOverride = scanner
    let window = try #require(controller.window)
    defer { window.close() }
    #expect(!window.isVisible, "App integration keeps the native window offscreen")
    window.setContentSize(NSSize(width: 1280, height: 800))
    func present() { window.update(); window.contentView?.layoutSubtreeIfNeeded() }
    func row(_ url: URL) -> GridSidebarFolderButton? {
        sidebar454Find(GridSidebarFolderButton.self, in: window.contentView) {
            $0.folderURL.standardizedFileURL.path == url.standardizedFileURL.path
        }
    }
    func footer() -> NSTextField? {
        sidebar454Find(NSTextField.self, in: window.contentView) {
            $0.accessibilityIdentifier() == "grid.folder-count"
        }
    }
    func expectedAX(_ url: URL, count: Int) -> String {
        "\(url.lastPathComponent), \(String(format: String(localized: "%lld images"), Int64(count)))"
    }
    try await withAsyncTeardown {
        // Use the existing entry after a real grant, without ordering a window onto the desktop.
        controller.browseRecoveredFolder(folder, rootID: rootID)
        // SidebarFolderLoadSession counts current before children. Child=1 proves the real
        // independent session has delivered its current-folder count, without injecting one.
        try await MadoAppTests.waitUntil("real sidebar counts and held main scan", between: { present() }) {
            scanner.isHolding && row(child)?.countLabel.stringValue == "1"
                && controller.session.folderScan?.isReadingFolder == true
                && footer()?.stringValue == String(localized: "Reading…")
        }
        present()
        let scan = try #require(controller.session.folderScan)
        let readingRow = try #require(row(folder))
        let childRow = try #require(row(child))
        let status = try #require(footer())
        #expect(!window.isVisible, "reading-state inspection must remain offscreen")
        #expect(scan.isReadingFolder)
        #expect(scan.sourceSnapshot?.isComplete == false)
        #expect(scan.sourceSnapshot?.navigationEntries.count == 3)
        #expect(readingRow.current)
        #expect(status.stringValue == String(localized: "Reading…"))
        print("i454 repro mainReading=\(scan.isReadingFolder) currentCount=\(readingRow.countLabel.stringValue) childCount=\(childRow.countLabel.stringValue) footer=\(status.stringValue)")

        // Pinned folder-loading.html page 24 has no row-count on the folder being read.
        #expect(readingRow.countLabel.stringValue.isEmpty, "reading folder count must be blank")
        #expect(readingRow.countLabel.isHidden, "reading folder count must be hidden")
        #expect(readingRow.accessibilityLabel() == folder.lastPathComponent,
                "reading folder AX must not announce an independently completed count")
        #expect(childRow.countLabel.stringValue == "1")
        #expect(!childRow.countLabel.isHiddenOrHasHiddenAncestor)
        #expect(childRow.accessibilityLabel() == expectedAX(child, count: 1))

        scanner.release()
        try await MadoAppTests.waitUntil("main scan completed with final count", between: { present() }) {
            scan.sourceSnapshot?.isComplete == true && !scan.isScanning
                && row(folder)?.countLabel.stringValue == "3"
                && row(child)?.countLabel.stringValue == "1"
        }
        present()
        #expect(scan.sourceSnapshot?.navigationEntries.count == 3)
        #expect(!scan.isReadingFolder)
        #expect(!window.isVisible, "completed-state inspection must remain offscreen")
        let completed = try #require(row(folder))
        #expect(completed.countLabel.stringValue == "3")
        #expect(!completed.countLabel.isHiddenOrHasHiddenAncestor)
        #expect(completed.accessibilityLabel() == expectedAX(folder, count: 3))
        #expect(row(child)?.countLabel.stringValue == "1")
        #expect(row(child)?.countLabel.isHiddenOrHasHiddenAncestor == false)
        #expect(row(child)?.accessibilityLabel() == expectedAX(child, count: 1))
    } teardown: {
        scanner.release()
        // Close cancels controller-owned navigation, scan and sidebar work. Await the real
        // scanner before the enclosing defer removes its filesystem fixture.
        window.close()
        try? await MadoAppTests.waitUntil("held scanner teardown") { scanner.allEnded }
    }
}
