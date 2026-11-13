import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue573Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private final class Issue573DenyTarget: SecurityScope, @unchecked Sendable {
    let target: URL
    init(target: URL) { self.target = target }
    func start(_ url: URL) -> Bool { url != target }
    func isReadable(_ url: URL) -> Bool { url != target }
    func stop(_ url: URL) { }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue573DeniedSymlinkTargetShowsChooseFileRecovery() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let tree = fm.temporaryDirectory.appendingPathComponent("issue573-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tree) }
    let target = tree.appendingPathComponent("image.png")
    let link = tree.appendingPathComponent("link.png")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try fm.copyItem(at: fixture, to: target)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    let access = try FileAccess(scope: Issue573DenyTarget(target: target), bookmarks: SystemSecurityScope(),
        store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "issue573")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: tree.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue573Motion()))
    let window = try #require(controller.window)
    defer { window.close() }

    controller.openInput([link])
    try await waitUntil("input should settle or show choose-file recovery") {
        window.attachedSheet != nil || controller.session.imageLoader.phase == .settled
    }

    #expect(controller.session.imageLoader.presented == nil)
    let sheet = try #require(window.attachedSheet)
    func labels(_ view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(labels)
    }
    #expect(labels(try #require(sheet.contentView)).contains(String(localized: "Choose this image again to reconnect access.")))
    #expect(await access.records().isEmpty)
}
