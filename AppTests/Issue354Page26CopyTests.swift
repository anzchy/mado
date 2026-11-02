import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

/// The OS bookmark boundary is deterministic; folders, scan, controller copy and AppKit views are real.
private struct Page26CopyBookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}
@MainActor private final class Page26CopyMotion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}
@MainActor private func page26CopyFind<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    return (view as? T) ?? view.subviews.lazy.compactMap { page26CopyFind(type, in: $0) }.first
}

@Suite(.serialized) @MainActor struct Issue354Page26CopyTests {
    /// #354 row2: actual controller output for two real folder names per cause.
    /// AppTests excludes App/Resources, so this host verifies English fallback. Chinese catalog/layout
    /// is independently covered by Page26CopyLayoutTests; compiled zh-Hans App remains device verification.
    @Test(.timeLimit(.minutes(2))) func titlesUseTheActualFolderForBothCauses() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("i354-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let adapter = Page26CopyBookmarks()
        let files = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "i354-copy")
        let services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Page26CopyMotion()))
        let window = try #require(controller.window)
        defer { window.close() }
        func waitUntil(_ condition: () -> Bool) async throws {
            while !condition() { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
        }
        for name in ["待整理", "旅行照片 2026"] {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let root = try await files.grant(folder: folder)
            for cause in [AccessLossCause.notFound, .accessExpired] {
                await services.monitor.reauthorize(root)
                controller.browseRecoveredFolder(folder, rootID: root)
                try await waitUntil { controller.waitingAccessPosition == nil && controller.session.folderScan?.snapshot?.isComplete == true && controller.session.folderScan?.snapshot?.version.folder == folder }
                #expect(services.monitor.state.reportRootFailure(root, cause: cause, from: services.monitor.state.stamp(for: root)))
                try await waitUntil { controller.accessLossCause == cause && controller.waitingAccessPosition?.folderURL == folder }
                let page = try #require(page26CopyFind(LostAccessStateView.self, in: window.contentView))
                let expected = cause == .notFound ? "Can’t Find “\(name)”" : "Unable to Access “\(name)”"
                #expect(page.titleLabel.stringValue == expected)
                controller.showWaitingAccessState()
                #expect(page.titleLabel.stringValue == expected)
                #expect(!page.titleLabel.stringValue.contains("%@"))
                if cause == .notFound {
                    #expect(page.detailLabel.stringValue.replacingOccurrences(of: "\n", with: " ") == "picsee can’t find “\(name)”. Choose its location, or choose another folder to continue.")
                }
                let shell = try #require(page26CopyFind(GridShellView.self, in: window.contentView))
                #expect(shell.displayButton.isEnabled)
                await Task.yield()
            }
        }
    }
}
