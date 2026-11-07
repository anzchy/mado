import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private struct Issue281Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        guard let path = String(data: data, encoding: .utf8) else { throw FileAccessError.corruptStore }
        return ResolvedBookmark(url: URL(fileURLWithPath: path), stale: false)
    }
}

/// Lists the folder's files, holds folders named `Hold` until cancelled, and stops the first scan of `Retry` part way.
private final class Issue281Scanner: FolderScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    func allowRetry() { lock.withLock { failing = false } }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        if folder.lastPathComponent == "Hold" { try await Task.sleep(for: .seconds(3600)) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let entries = files.map { FolderEntry(url: $0, root: root) }
        if folder.lastPathComponent == "Retry", lock.withLock({ failing }) {
            // The read stops part way, after the first image.
            try await emit(Array(entries.prefix(1)))
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        }
        try await emit(entries)
    }
}

@MainActor private final class Issue281MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue281View(_ id: String, in view: NSView?) -> NSView? {
    guard let view else { return nil }
    if view.accessibilityIdentifier() == id || view.identifier?.rawValue == id { return view }
    return view.subviews.lazy.compactMap { issue281View(id, in: $0) }.first
}

/// #437: inspect the installed controls, including the ink that AppKit used to dim when disabled.
/// design/prototypes/picsee-browser/states/{grid-light,folder-loading}.html at 1280×800:
/// muted #6b7280; tiny-button x155. Their @media (max-width:1050px) changes sidebar
/// horizontal padding from 12 to 8, moving the control to x159 in a 196pt sidebar.
@MainActor private func issue437ExpectSidebarInk(in root: NSView) throws {
    root.layoutSubtreeIfNeeded()
    let tree = try #require(issue281View("grid.sidebar.add-folder", in: root)?.superview)
    for id in ["grid.sidebar.add-folder", "grid.sidebar.add-folder-plus"] {
        let button = try #require(issue281View(id, in: root) as? NSButton)
        #expect(!button.isEnabled)
        #expect(button.refusesFirstResponder)
        #expect(button.accessibilityLabel() == "\(String(localized: "Add Folder")) · \(String(localized: "Coming Soon"))")
        if id.hasSuffix("-plus") {
            let x = tree.convert(button.bounds, from: button).minX
            let geometry = "header plus x=\(x), window=\(String(describing: root.window?.frame)), "
                + "content=\(root.bounds), sidebar=\(tree.bounds), "
                + "screen=\(String(describing: root.window?.screen?.frame)), "
                + "visibleScreen=\(String(describing: root.window?.screen?.visibleFrame))"
            #expect(root.bounds.width == 1280, "1280pt design viewport required: \(geometry)")
            #expect(abs(x - 155) <= 1, "\(geometry)")
        }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(button.bounds.width), pixelsHigh: Int(button.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: bitmap)
        func inkCount(_ area: NSRect, minimumAlpha: CGFloat) -> Int {
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where area.contains(NSPoint(x: CGFloat(x), y: CGFloat(y))) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.alphaComponent > minimumAlpha && abs(c.redComponent - 107.0 / 255) < 0.08
                        && abs(c.greenComponent - 114.0 / 255) < 0.08
                        && abs(c.blueComponent - 128.0 / 255) < 0.08 { count += 1 }
                }
            }
            return count
        }
        if id.hasSuffix("-plus") {
            // A 1.02pt SVG stroke straddles pixels: its full-opacity paint can rasterize below .85 alpha.
            // The MacUI SVG-mask oracle verifies the exact alpha coverage independently.
            #expect(inkCount(button.bounds.insetBy(dx: 3, dy: 3), minimumAlpha: 0.2) > 0,
                "header plus visibly uses the muted token")
        } else {
            let textWidth = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let start = (button.bounds.width - (15 + 7 + textWidth)) / 2
            #expect(inkCount(NSRect(x: start, y: 7, width: 15, height: 16), minimumAlpha: 0.2) > 0,
                "add-folder plus is painted inside its box")
            #expect(inkCount(NSRect(x: start + 22, y: 5, width: textWidth, height: 20), minimumAlpha: 0.85) > 3,
                "add-folder label visibly uses the muted token")
        }
    }
}

/// Audit M1: the footer's name and count across the real open-folder path (completion, Cancel Reading through the
/// restore closure, failure and Retry, and back from the viewer), each label wide enough for its whole string.
@Test(.timeLimit(.minutes(3))) @MainActor func issue281FooterFollowsTheOpenFolderPathUntruncated() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("issue281-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    var folders: [String: URL] = [:]
    for (name, files) in [("Shown", ["DSC_0341.png", "DSC_0342.png", "DSC_0343.png"]), ("Hold", ["H.png"]),
                          ("Retry", ["山海之间_0001.png", "山海之间_0002.png"])] {
        let folder = base.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try data.write(to: folder.appendingPathComponent(file)) }
        folders[name] = folder
    }
    let adapter = Issue281Bookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue281")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue281MotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    window.appearance = NSAppearance(named: .aqua)
    let scanner = Issue281Scanner()
    controller.folderScanningOverride = scanner
    controller.showWindow(nil)
    window.orderFrontRegardless()
    // Showing a window can constrain its frame to the runner's screen. Pin the design
    // viewport afterwards so the x155 assertion never silently uses the <=1050 breakpoint.
    window.setContentSize(NSSize(width: 1280, height: 800))

    func waitUntil(_ condition: () -> Bool, fileID: String = #fileID, line: Int = #line) async throws {
        try await MadoAppTests.waitUntil(fileID: fileID, line: line, between: { window.update() }, condition)
    }
    func footer() throws -> (name: NSTextField, count: NSTextField) {
        (try #require(issue281View("grid.current-file-status", in: window.contentView) as? NSTextField),
         try #require(issue281View("grid.folder-count", in: window.contentView) as? NSTextField))
    }
    func expectFooter(_ name: String, _ count: String, _ step: String) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let (nameLabel, countLabel) = try footer()
        #expect(nameLabel.stringValue == name, "\(step): name")
        #expect(countLabel.stringValue == count, "\(step): count")
        for label in [nameLabel, countLabel] {
            #expect(!label.isHidden, "\(step): \(label.stringValue) shown")
            #expect(label.frame.width >= ceil(label.cell?.cellSize.width ?? .infinity),
                    "\(step): \(label.stringValue) truncated")
        }
    }

    // Completion.
    controller.openGrantedFolder(try #require(folders["Shown"]))
    try await waitUntil { controller.gridSearchAvailable }
    try expectFooter("DSC_0341.png", "3 images", "completion")
    try issue437ExpectSidebarInk(in: try #require(window.contentView))

    // A read that stops part way, then Retry (what the failure page's Retry calls). A folder prompt the failed
    // open may attach is dismissed first.
    controller.openGrantedFolder(try #require(folders["Retry"]))
    try await waitUntil { controller.session.folderScan?.failure != nil }
    // Fix round 5: a failed read must not keep the reading footer.
    window.contentView?.layoutSubtreeIfNeeded()
    // #238: the pinned 24F-A footer keeps the dash in the name slot and reads 「读取未完成」.
    #expect(try footer().name.stringValue == "—", "failure: name")
    #expect(try footer().count.stringValue != String(localized: "Reading…"), "failure: count")
    #expect(try footer().count.stringValue == String(localized: "Read incomplete"), "failure: count")
    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    scanner.allowRetry()
    controller.session.retryFolderScan()
    try await waitUntil { controller.gridSearchAvailable && controller.session.folderScan?.failure == nil }
    try expectFooter("山海之间_0001.png", "2 images", "retry")

    // Into the viewer and back.
    let router = CommandRouter()
    #expect(router.route(.enter, from: .key, to: controller.session))
    try await waitUntil { controller.session.mode == .viewing }
    #expect(router.route(.escape, from: .key, to: controller.session))
    try await waitUntil { controller.gridSearchAvailable }
    try expectFooter("山海之间_0001.png", "2 images", "viewer return")

    // Reading another folder, then Cancel Reading through the restore closure.
    controller.openGrantedFolder(try #require(folders["Hold"]))
    try await waitUntil { controller.session.folderScan?.isReadingFolder == true }
    try await waitUntil { issue281View("state.cancel-folder", in: window.contentView) != nil }
    try expectFooter("—", "Reading…", "reading")
    try issue437ExpectSidebarInk(in: try #require(window.contentView))
    let cancel = try #require(issue281View("state.cancel-folder", in: window.contentView) as? NSButton)
    cancel.performClick(nil)
    try await waitUntil { controller.gridSearchAvailable }
    try expectFooter("山海之间_0001.png", "2 images", "cancel restored")
}

/// Holds each read of the folder until released; the first read stops part way, after the first image.
private final class Issue281GatedRetryScanner: FolderScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0, released = 0
    var started: Int { lock.withLock { attempts } }
    func release() { lock.withLock { released += 1 } }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let attempt = lock.withLock { attempts += 1; return attempts }
        while lock.withLock({ released < attempt }) { try await Task.sleep(for: .milliseconds(10)) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let entries = files.map { FolderEntry(url: $0, root: root) }
        if attempt == 1 {
            try await emit(Array(entries.prefix(1)))
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        }
        try await emit(entries)
    }
}

/// The sidebar's own image count, held until released, so a test can choose when the sidebar learns it (#379).
private actor Issue281GatedSidebarCounter: SidebarFolderEnumerating {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func children(in folder: URL, root: URL) -> [URL] { [] }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.count
    }
    func release() { released = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

/// Fix round 6 (gpt-auditor F1): Retry on the failed-read page starts a read on the shell's reading surface, so the
/// footer shows `—` / `Reading…` and the sidebar counts as for a first read until the retry completes.
@Test(.timeLimit(.minutes(3))) @MainActor func issue281RetryAfterFailedReadShowsTheReadingFooter() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("issue281-retry-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    let folder = base.appendingPathComponent("Retry")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in ["山海之间_0001.png", "山海之间_0002.png"] { try data.write(to: folder.appendingPathComponent(file)) }
    let adapter = Issue281Bookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue281")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue281MotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let scanner = Issue281GatedRetryScanner()
    controller.folderScanningOverride = scanner
    let counter = Issue281GatedSidebarCounter()
    controller.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: counter)
    window.setContentSize(NSSize(width: 1280, height: 772))
    controller.showWindow(nil)
    window.orderFrontRegardless()

    func waitUntil(_ condition: () -> Bool, fileID: String = #fileID, line: Int = #line) async throws {
        try await MadoAppTests.waitUntil(fileID: fileID, line: line, between: { window.update() }, condition)
    }
    func footer() throws -> (name: String, count: String) {
        window.contentView?.layoutSubtreeIfNeeded()
        let name = try #require(issue281View("grid.current-file-status", in: window.contentView) as? NSTextField)
        let count = try #require(issue281View("grid.folder-count", in: window.contentView) as? NSTextField)
        return (name.isHidden ? "" : name.stringValue, count.isHidden ? "" : count.stringValue)
    }
    func sidebarCount() -> String? {
        guard let shell = window.contentView?.subviews.compactMap({ $0 as? GridShellView }).first,
              let row = shell.folderTree.rows.first(where: { $0.current }) else { return nil }
        return row.countLabel.isHidden ? "" : row.countLabel.stringValue
    }

    // First read, held: the reading footer and the sidebar's count for the folder being read.
    controller.openGrantedFolder(folder)
    try await waitUntil { scanner.started == 1 && controller.session.folderScan?.isReadingFolder == true }
    try await waitUntil { issue281View("state.cancel-folder", in: window.contentView) != nil }
    #expect(try footer() == ("—", "Reading…"), "first read")
    // The sidebar counts the folder on its own; while that count is held, it stays blank.
    #expect(sidebarCount() == "", "first read: unknown count is blank")
    let firstReadShowsZero = window.contentView?.subviews.compactMap({ $0 as? GridShellView }).first?
        .folderTree.showsZeroForUnknownCurrent
    // #379: the order CI hit, forced: the sidebar learns the real count before the read fails.
    await counter.release()
    try await waitUntil { sidebarCount() == "2" }

    // It stops part way; the failure page's Retry, held.
    scanner.release()
    try await waitUntil { controller.session.folderScan?.failure != nil }
    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    try await waitUntil { issue281View("state.retry-folder", in: window.contentView) != nil }
    let retry = try #require(issue281View("state.retry-folder", in: window.contentView) as? NSButton)
    retry.performClick(nil)
    try await waitUntil { scanner.started == 2 && controller.session.folderScan?.isReadingFolder == true }
    #expect(try footer() == ("—", "Reading…"), "held retry")
    // #238: a held retry keeps the folder's known count, never the failed read's `—`.
    #expect(sidebarCount() == "2", "held retry: the known count, not the failed read's dash")
    #expect(firstReadShowsZero == false && window.contentView?.subviews.compactMap({ $0 as? GridShellView }).first?
        .folderTree.showsZeroForUnknownCurrent == firstReadShowsZero, "held retry: unknown count stays blank as for a first read")

    // Released: the completed name and count.
    scanner.release()
    try await waitUntil { controller.gridSearchAvailable && controller.session.folderScan?.failure == nil }
    #expect(try footer() == ("山海之间_0001.png", "2 images"), "retry completed")
}
