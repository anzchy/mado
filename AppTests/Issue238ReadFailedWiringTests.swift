import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

/// #238 (P3-17c D3): 「读取失败」 (24F-A) in the grid shell's content area, and its boundary with page 26.
private struct Issue238Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        guard let path = String(data: data, encoding: .utf8) else { throw FileAccessError.corruptStore }
        return ResolvedBookmark(url: URL(fileURLWithPath: path), stale: false)
    }
}

/// Scripted per attempt: optionally held until released, then lists the folder's PNGs and fails after `after` of them.
private final class Issue238Scanner: FolderScanning, @unchecked Sendable {
    struct Step: Sendable {
        var hold = false
        var failure: (any Error & Sendable)?
        var after = 1
    }
    private let lock = NSLock()
    private var script: [Step]
    private var released: Set<Int> = []
    private var count = 0
    init(_ script: [Step]) { self.script = script }
    var started: Int { lock.withLock { count } }
    func release(_ attempt: Int) { _ = lock.withLock { released.insert(attempt) } }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let (attempt, step) = lock.withLock { () -> (Int, Step) in
            defer { count += 1 }
            return (count, count < script.count ? script[count] : Step())
        }
        if step.hold { while !lock.withLock({ released.contains(attempt) }) { try await Task.sleep(for: .milliseconds(10)) } }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let entries = files.map { FolderEntry(url: $0, root: root) }
        if let failure = step.failure {
            try await emit(Array(entries.prefix(step.after)))
            throw failure
        }
        try await emit(entries)
    }
}

@MainActor private final class Issue238MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue238Find<T: NSView>(_ type: T.Type, in view: NSView?, _ match: (T) -> Bool = { _ in true }) -> T? {
    guard let view else { return nil }
    if let view = view as? T, match(view) { return view }
    for subview in view.subviews { if let found = issue238Find(type, in: subview, match) { return found } }
    return nil
}

@MainActor private final class Issue238Scene {
    let base: URL
    let folder: URL
    let child: URL
    let controller: CanvasWindowController
    let window: NSWindow
    let scanner: Issue238Scanner?
    init(_ script: [Issue238Scanner.Step]?, childImages: Int = 2) throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("issue238-\(UUID().uuidString)")
        folder = base.appendingPathComponent("待整理")
        child = folder.appendingPathComponent("Child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: fixture)
        for name in ["img1.png", "img2.png"] { try data.write(to: folder.appendingPathComponent(name)) }
        for index in 0..<childImages { try data.write(to: child.appendingPathComponent("c\(index).png")) }
        let adapter = Issue238Bookmarks()
        let access = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue238")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: Issue238MotionSource()))
        window = try #require(controller.window)
        scanner = script.map(Issue238Scanner.init)
        if let scanner { controller.folderScanningOverride = scanner }
        window.setContentSize(NSSize(width: 1280, height: 772))
        controller.showWindow(nil)
        window.orderFrontRegardless()
    }
    func close() {
        window.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
        try? FileManager.default.removeItem(at: base)
    }
    func tick() async throws { window.update(); try await Task.sleep(for: .milliseconds(10)) }
    /// No wall-clock deadline (#277): the test's time limit cancels the sleep, which ends the wait.
    func waitUntil(_ condition: () -> Bool, each: () -> Void = {}) async throws {
        while !condition() { each(); try await tick() }
        each()
    }
    var readFailed: ReadFailedStateView? {
        issue238Find(ReadFailedStateView.self, in: window.contentView) { !$0.isHiddenOrHasHiddenAncestor }
    }
    func visible(_ id: String) -> Bool {
        issue238Find(NSView.self, in: window.contentView) {
            ($0.accessibilityIdentifier() == id || $0.identifier?.rawValue == id) && !$0.isHiddenOrHasHiddenAncestor
        } != nil
    }
    var shell: GridShellView? { issue238Find(GridShellView.self, in: window.contentView) }
    func footer() throws -> (name: String, count: String) {
        window.contentView?.layoutSubtreeIfNeeded()
        let name = try #require(issue238Find(NSTextField.self, in: window.contentView) { $0.accessibilityIdentifier() == "grid.current-file-status" })
        let count = try #require(issue238Find(NSTextField.self, in: window.contentView) { $0.accessibilityIdentifier() == "grid.folder-count" })
        return (name.stringValue, count.stringValue)
    }
    func row(_ url: URL) -> GridSidebarFolderButton? {
        issue238Find(GridSidebarFolderButton.self, in: window.contentView) { $0.folderURL.standardizedFileURL == url.standardizedFileURL }
    }
    func dismissSheet() { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) } }
    /// What 24F-A shows: footer, sidebar row, controls and focus.
    func observed() throws -> [String] {
        let page = try #require(readFailed)
        let (name, count) = try footer()
        return [page.titleLabel.stringValue, page.detailLabel.stringValue, name, count,
                row(folder)?.countLabel.stringValue ?? "no row",
                page.buttons.map { $0.identifier?.rawValue ?? "" }.joined(separator: ","),
                window.firstResponder === page.retryButton ? "focus:retry" : "focus:other"]
    }
}

private let issue238ReadError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)

@Test(.timeLimit(.minutes(3))) @MainActor func issue238ReadableRootShowsReadFailedInContentArea() async throws {
    let scene = try Issue238Scene([.init(failure: issue238ReadError, after: 1)])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil({ scene.readFailed != nil }) {
        #expect(!scene.visible("access.lost.state"), "page 26 never appears for a readable root")
    }
    scene.dismissSheet()
    let page = try #require(scene.readFailed)
    let shell = try #require(scene.shell)
    let pageFrame = page.convert(page.bounds, to: nil), content = shell.mainContent.convert(shell.mainContent.bounds, to: nil)
    #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(pageFrame) && pageFrame.width > 0)
    #expect(page.titleLabel.stringValue == "Couldn't finish reading “待整理”")
    #expect(page.accessibilityLabel() == page.titleLabel.stringValue && page.accessibilityValue() as? String == page.detailLabel.stringValue)
    #expect(page.retryButton.accessibilityLabel() == "Retry" && page.chooseOtherButton.accessibilityLabel() == "Choose Another Folder…")
    #expect(scene.window.firstResponder === page.retryButton)
    #expect(page.retryButton.nextValidKeyView === page.chooseOtherButton)
    #expect(scene.controller.session.folderScan?.sourceSnapshot == nil)
    #expect(!scene.controller.gridSearchAvailable)
    #expect(try scene.footer() == ("–", "Read incomplete"))
    #expect(scene.row(scene.folder)?.countLabel.stringValue == "—")
    // The sidebar stays usable: another folder opens from it.
    try #require(scene.row(scene.child)).performClick(nil)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    #expect(scene.readFailed == nil)
    #expect(try scene.footer().count == "2 images")
    #expect(!scene.visible("access.lost.state"))
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238RemovedRootShowsLostAccessWithoutReadFailedFlash() async throws {
    let scene = try Issue238Scene([.init(hold: true, failure: POSIXError(.ENOENT), after: 0)])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.scanner?.started == 1 }
    try FileManager.default.removeItem(at: scene.folder)
    scene.scanner?.release(0)
    func neverReadFailed() {
        #expect(!scene.visible("state.retry-folder"), "no 24F-A before or after page 26")
        // A Bool, so a RED never prints the ENOENT description (the receipt reads it as an environment failure).
        let failed = scene.controller.session.folderScan?.failure != nil
        #expect(!failed, "no read failure published for a lost root")
        #expect(!scene.visible("state.open"), "no first launch in between")
    }
    try await scene.waitUntil({ scene.visible("access.lost.state") }, each: neverReadFailed)
    // Page 26 survives the scan's end (adversary gap 2).
    try await scene.waitUntil({ scene.controller.session.folderScan?.isScanning != true }) {
        neverReadFailed(); #expect(scene.visible("access.lost.state"))
    }
    for _ in 0..<20 { try await scene.tick(); neverReadFailed(); #expect(scene.visible("access.lost.state")) }
    let first = try #require(issue238Find(LostAccessStateView.self, in: scene.window.contentView)?.buttons.first)
    #expect(scene.window.firstResponder === first)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238RemovedDescendantWithReadableRootShowsReadFailed() async throws {
    let scene = try Issue238Scene([.init(hold: true, failure: POSIXError(.ENOENT), after: 1), .init()])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.scanner?.started == 1 }
    try FileManager.default.removeItem(at: scene.child)
    scene.scanner?.release(0)
    try await scene.waitUntil({ scene.readFailed != nil }) { #expect(!scene.visible("access.lost.state")) }
    scene.dismissSheet()
    #expect(scene.readFailed?.titleLabel.stringValue == "Couldn't finish reading “待整理”")
    for _ in 0..<20 { try await scene.tick(); #expect(!scene.visible("access.lost.state")) }
    // The root kept its permit: reading it again completes.
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    #expect(try scene.footer().count == "2 images")
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238UnreadableSubfolderWithReadableRootShowsReadFailed() async throws {
    let scene = try Issue238Scene(nil)
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: scene.child.path)
    _ = scene.controller.session.setFolderRecursiveEnabled(true)
    try await scene.waitUntil({ scene.readFailed != nil }) { #expect(!scene.visible("access.lost.state")) }
    #expect(scene.readFailed?.titleLabel.stringValue == "Couldn't finish reading “待整理”")
    #expect(scene.controller.session.folderScan?.failureReason == "Folder access denied")
    for _ in 0..<20 { try await scene.tick(); #expect(!scene.visible("access.lost.state")) }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238UnreadableChildScanShowsOnlyReadFailed() async throws {
    let readDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    let scene = try Issue238Scene([.init(), .init(failure: readDenied, after: 1)])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.controller.gridSearchAvailable && scene.row(scene.child) != nil }
    try #require(scene.row(scene.child)).performClick(nil)
    try await scene.waitUntil { scene.readFailed != nil }
    for _ in 0..<20 { try await scene.tick() }
    #expect(scene.readFailed?.titleLabel.stringValue == "Couldn't finish reading “Child”")
    #expect(!scene.visible("access.lost.state"))
    #expect(scene.window.attachedSheet == nil, "a readable Access Root must not produce a folder grant sheet for a child read failure")
}

/// Audit M1: a failed reread on the viewer surface must not cover the shown image with 24F-A.
@Test(.timeLimit(.minutes(3))) @MainActor func issue238ViewerReadFailureKeepsImageAndArrowNavigation() async throws {
    let scene = try Issue238Scene([.init(), .init(failure: issue238ReadError, after: 1)])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    let scan = try #require(scene.controller.session.folderScan)
    try await scene.waitUntil { !scan.isScanning && scan.completedImageCount == 2 }
    let first = try #require(scan.snapshot?.navigationEntries.first)
    scene.controller.session.focus(first.itemID)
    try #require(scene.controller.route(.enter, from: .key))
    try await scene.waitUntil {
        scene.controller.session.mode == .viewing && scene.controller.hasImage &&
            scene.controller.session.imageStatus == .showing
    }
    #expect(scene.controller.session.imageLoader.fileURL?.lastPathComponent == "img1.png")

    _ = try? await scan.refresh()?.value
    try await scene.waitUntil { scan.failureReason != nil }
    for _ in 0..<5 { try await scene.tick() }
    #expect(scene.controller.hasImage && scene.controller.session.imageLoader.presented != nil)
    #expect(scene.readFailed == nil, "24F-A must stay on the folder-entry reading surface")
    #expect(scene.visible("state.retry-folder"), "the viewer keeps its non-covering failure state")

    func arrow(_ keyCode: UInt16, _ characters: String) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: scene.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        scene.window.sendEvent(event)
    }
    try arrow(124, "\u{F703}")
    try await scene.waitUntil {
        scene.controller.session.imageLoader.fileURL?.lastPathComponent == "img2.png" &&
            scene.controller.hasImage && scene.controller.session.imageLoader.presented != nil
    }
    #expect(scene.controller.hasImage && scene.readFailed == nil)
    try arrow(123, "\u{F702}")
    try await scene.waitUntil {
        scene.controller.session.imageLoader.fileURL?.lastPathComponent == "img1.png" &&
            scene.controller.hasImage && scene.controller.session.imageLoader.presented != nil
    }
    #expect(scene.controller.hasImage && scene.readFailed == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238RetrySucceedsThenRetryFailsReturnsToReadFailed() async throws {
    let scene = try Issue238Scene([.init(failure: issue238ReadError, after: 1), .init(failure: issue238ReadError, after: 1), .init()])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.readFailed != nil }
    scene.dismissSheet()
    let first = try scene.observed()
    #expect(first.last == "focus:retry")
    try #require(scene.readFailed).retryButton.performClick(nil)
    try await scene.waitUntil { scene.scanner?.started == 2 && scene.readFailed != nil && scene.controller.session.folderScan?.isScanning == false }
    scene.dismissSheet()
    #expect(try scene.observed() == first)
    try #require(scene.readFailed).retryButton.performClick(nil)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    #expect(scene.scanner?.started == 3 && scene.readFailed == nil)
    #expect(try scene.footer() == ("img1.png", "2 images"))
}

@Test(.timeLimit(.minutes(1))) @MainActor func issue238CancelDuringRetryRestoresReadFailedPage() async throws {
    let scene = try Issue238Scene([.init(failure: issue238ReadError, after: 1), .init(hold: true), .init(hold: true)])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.readFailed != nil }
    scene.dismissSheet()
    let failed = try scene.observed()
    try #require(scene.readFailed).retryButton.performClick(nil)
    try await scene.waitUntil { scene.scanner?.started == 2 && scene.visible("state.cancel-folder") }
    #expect(try scene.footer() == ("–", "Reading…"))
    let cancel = try #require(issue238Find(NSButton.self, in: scene.window.contentView) { $0.identifier?.rawValue == "state.cancel-folder" })
    cancel.performClick(nil)
    try await scene.waitUntil { scene.readFailed != nil }
    #expect(try scene.observed() == failed)
    #expect(!scene.visible("state.open"))
    scene.scanner?.release(1)
    for _ in 0..<20 { try await scene.tick() }
    #expect(try scene.observed() == failed)
    try #require(scene.readFailed).retryButton.performClick(nil)
    try await scene.waitUntil { scene.scanner?.started == 3 }
    scene.scanner?.release(2)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238ChooseOtherFolderRequestsOpenPanel() async throws {
    let scene = try Issue238Scene([.init(failure: issue238ReadError, after: 1)])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.readFailed != nil }
    scene.dismissSheet()
    var requests = 0
    scene.controller.onOpenRequest = { requests += 1 }
    try #require(scene.readFailed).chooseOtherButton.performClick(nil)
    #expect(requests == 1 && scene.scanner?.started == 1 && scene.readFailed != nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue238ScanLimitShowsReadFailedWithoutLosingRoot() async throws {
    let scene = try Issue238Scene([.init(failure: FolderScanLimitError.entryLimit(limit: 1, admittedImages: 1), after: 1), .init()])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil({ scene.readFailed != nil }) { #expect(!scene.visible("access.lost.state")) }
    scene.dismissSheet()
    #expect(scene.readFailed?.titleLabel.stringValue == "Couldn't finish reading “待整理”")
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    #expect(!scene.visible("access.lost.state"))
}

/// Review H1: a silent refresh that fails on a shown grid keeps the grid and its footer; 24F-A belongs to the
/// reading surface, and a later successful refresh leaves nothing of the failed mode behind.
@Test(.timeLimit(.minutes(3))) @MainActor func issue238RefreshFailureOnGridKeepsTheGridFooter() async throws {
    let scene = try Issue238Scene([.init(), .init(failure: issue238ReadError, after: 1), .init()])
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { scene.controller.gridSearchAvailable }
    let shown = try scene.footer()
    let scan = try #require(scene.controller.session.folderScan)
    // A refresh starts only once the open's scan has fully ended.
    try await scene.waitUntil { !scan.isScanning && scan.completedImageCount != nil }
    _ = try? await scan.refresh()?.value
    #expect(scan.failure != nil && scene.scanner?.started == 2)
    for _ in 0..<5 { try await scene.tick() }
    scene.dismissSheet()
    #expect(try scene.footer() == shown, "failed refresh: grid footer kept")
    #expect(scene.row(scene.folder)?.countLabel.stringValue != "—")
    #expect(scene.shell?.searchButton.isEnabled == true && scene.shell?.sortButton.isEnabled == true)
    try await scene.waitUntil { !scan.isScanning }
    _ = try? await scan.refresh()?.value
    for _ in 0..<5 { try await scene.tick() }
    #expect(scan.failure == nil && scene.scanner?.started == 3)
    #expect(try scene.footer() == shown, "recovered refresh: grid footer")
    #expect(scene.row(scene.folder)?.countLabel.stringValue != "—")
    #expect(scene.shell?.searchButton.isEnabled == true && scene.shell?.sortButton.isEnabled == true)
}
