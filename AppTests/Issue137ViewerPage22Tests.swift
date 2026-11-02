import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private final class Issue137MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue137Wait(_ stage: String, detail: () -> String = { "" },
                                      _ condition: () -> Bool) async throws {
    try await waitUntil { condition() }
    try #require(condition(), "Issue 137 stage: \(stage) \(detail())")
}

private func issue137SamePath(_ lhs: URL?, _ rhs: URL) -> Bool {
    lhs?.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
}

/// A real controller over a temporary root; `base` is removed by the caller.
@MainActor private func issue137Controller(_ base: URL) async throws -> (CanvasWindowController, AccessRootID) {
    _ = NSApplication.shared
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue137-viewer")
    let root = try await access.grant(folder: base)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue137MotionSource()))
    return (controller, root)
}

@MainActor private func issue137Views(_ controller: CanvasWindowController) throws -> (GridShellView, ViewerStateHost) {
    let content = try #require(controller.window?.contentView)
    return (try #require(content.subviews.compactMap { $0 as? GridShellView }.first),
            try #require(content.subviews.compactMap { $0 as? ViewerStateHost }.first))
}

/// Owner decision C (#137, 2026-10-29): a viewer folder session that ends up with nothing to show (here the opened
/// image is removed) renders page 22's content on the viewer surface, lists the folder's subfolders, and its tile
/// routes exactly as the grid page's tile does.
@Test(.timeLimit(.minutes(3))) @MainActor func issue137ViewerEmptyFolderShowsPage22AndTileOpensSubfolder() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trip = base.appendingPathComponent("Trip"), sub = trip.appendingPathComponent("Sub")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let image = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/portrait-2x3.png"))
    let opened = trip.appendingPathComponent("a.png")
    try image.write(to: opened)
    try image.write(to: sub.appendingPathComponent("b.png"))
    let (controller, _) = try await issue137Controller(base)
    defer { controller.window?.close() }
    let (shell, host) = try issue137Views(controller)
    controller.openInput([opened])
    try await issue137Wait("viewer shows the opened image") {
        controller.session.imageStatus == .showing && shell.isHidden &&
            controller.session.folderScan?.sourceSnapshot?.isComplete == true
    }
    try fm.removeItem(at: opened)
    _ = controller.session.folderScan?.refresh()
    try await issue137Wait("viewer page 22", detail: {
        "status \(controller.session.imageStatus) empty \(controller.session.isEmptyFolder) hostHidden \(host.isHidden) " +
            "surface \(host.surface) inHost \(host.emptyFolderView.superview === host) " +
            "tiles \(host.emptyFolderView.tiles.count) shellHidden \(shell.isHidden) mode \(controller.session.mode)"
    }) {
        controller.session.imageStatus == .emptyFolder && !host.isHidden &&
            host.emptyFolderView.superview === host && host.emptyFolderView.tiles.count == 1
    }
    let page = host.emptyFolderView
    #expect(shell.isHidden, "the viewer stays")
    #expect(!page.isHiddenOrHasHiddenAncestor && issue137SamePath(page.tiles.first?.url, sub))
    #expect(!host.textLines.contains(String(localized: "Open a folder to start browsing")))
    page.tiles[0].performClick(nil)
    try await issue137Wait("the tile opens the subfolder's grid") {
        issue137SamePath(controller.session.folderScan?.sourceSnapshot?.version.folder, sub) &&
            controller.session.folderScan?.sourceSnapshot?.isComplete == true && controller.gridSearchAvailable
    }
}

/// gpt M2: page 22 disables footer search, so the search command (menu validation reads `gridSearchAvailable`, the
/// key route checks it first) must not reveal the disabled field.
@Test(.timeLimit(.minutes(3))) @MainActor func issue137Page22RefusesSearchCommandEntry() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let empty = base.appendingPathComponent("Empty")
    try fm.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let (controller, root) = try await issue137Controller(base)
    defer { controller.window?.close() }
    let (shell, _) = try issue137Views(controller)
    controller.browseRecoveredFolder(empty, rootID: root)
    try await issue137Wait("grid page 22") { controller.session.isEmptyFolder && shell.emptyFolderVisible }
    #expect(!controller.gridSearchAvailable)
    #expect(!controller.route(.search, from: .key))
    #expect(shell.searchField.isHidden && !shell.searchButton.isHidden)
    let responder = controller.window?.firstResponder
    #expect(responder !== shell.searchField && responder !== shell.searchField.currentEditor())
}
