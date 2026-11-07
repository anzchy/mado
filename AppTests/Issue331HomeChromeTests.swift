import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// #331 (spec #311 amendment, 2026-10-31): 「我看到程序安装后，进入首页（没有加载文件夹和图片），还是用toolbar出现」, then
/// 「Hide all on Home (Recommended)」. The real controller's Home shows no viewer floating controls; an opened image does.
/// Tools are pinned (Always Show Tools), so the session always asks for them and only the Home can hide them.
@MainActor private final class Issue331MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue331Wait(_ stage: String, detail: () -> String = { "" },
                                      _ condition: () -> Bool) async throws {
    try await waitUntil { condition() }
    try #require(condition(), "Issue 331 stage: \(stage) \(detail())")
}

/// A real controller over a temporary root; `base` is removed by the caller.
@MainActor private func issue331Controller(_ base: URL) async throws -> (CanvasWindowController, AccessRootID) {
    _ = NSApplication.shared
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue331-home")
    let root = try await access.grant(folder: base)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(DisplayPreferences(alwaysShowTools: true)),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue331MotionSource()))
    return (controller, root)
}

@MainActor private struct Issue331Views {
    let content: NSView, canvas: CanvasView, state: ViewerStateHost, chrome: ViewerChromeOverlay, shell: GridShellView
    init(_ controller: CanvasWindowController) throws {
        content = try #require(controller.window?.contentView)
        canvas = try #require(content.subviews.compactMap { $0 as? CanvasView }.first)
        state = try #require(content.subviews.compactMap { $0 as? ViewerStateHost }.first)
        chrome = try #require(content.subviews.compactMap { $0 as? ViewerChromeOverlay }.first)
        shell = try #require(content.subviews.compactMap { $0 as? GridShellView }.first)
    }
    var toolPoint: NSPoint { chrome.tools[2].convert(NSPoint(x: 15, y: 14), to: content) }
    var keyLoop: [NSView] {
        var loop: [NSView] = []
        var view = canvas.nextKeyView
        while let next = view, next !== canvas, loop.count < 32 { loop.append(next); view = next.nextKeyView }
        return loop
    }
    var groupsHidden: Bool { chrome.groups.allSatisfy { $0.isHidden } }
    var groupsShown: Bool { chrome.groups.allSatisfy { !$0.isHidden } }
    func expectHome(_ stage: String) {
        let hit = content.hitTest(toolPoint)
        #expect(groupsHidden, "\(stage): the Home shows no viewer controls")
        #expect(!(hit is ChromeToolView) && !(hit?.isDescendant(of: chrome) ?? false),
                "\(stage): the controls are not hit-testable, got \(String(describing: hit))")
        #expect(chrome.accessibilityChildren()?.isEmpty == true, "\(stage): VoiceOver reaches no control")
        #expect(chrome.tools.allSatisfy { !$0.acceptsFirstResponder }, "\(stage): no control takes keyboard focus")
        #expect(!keyLoop.contains { $0 is ChromeToolView }, "\(stage): no control in the key loop")
        #expect(keyLoop.contains { $0.accessibilityIdentifier() == "state.open" },
                "\(stage): Choose Folder… stays in the key loop \(keyLoop.map { $0.accessibilityIdentifier() })")
    }
    func expectControls(_ stage: String) {
        let children = (chrome.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        #expect(groupsShown, "\(stage): the viewer controls show")
        #expect(content.hitTest(toolPoint) === chrome.tools[2], "\(stage): the 更多 control is hit-testable")
        #expect(chrome.tools.allSatisfy { tool in children.contains { $0 === tool } }, "\(stage): all 8 controls are accessible")
        #expect(keyLoop.contains { $0 is ChromeToolView }, "\(stage): the controls are in the key loop")
    }
}

private func issue331Image(in folder: URL) throws -> URL {
    let image = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/portrait-2x3.png"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("a.png")
    try image.write(to: url)
    return url
}

/// Opens one image and waits until it shows and its background folder scan has finished, so nothing reopens it later.
@MainActor private func issue331Open(_ controller: CanvasWindowController, _ views: Issue331Views, _ url: URL) async throws {
    controller.openInput([url])
    try await issue331Wait("image shows", detail: { "status \(controller.session.imageStatus)" }) {
        controller.session.imageStatus == .showing && views.shell.isHidden && views.groupsShown &&
            controller.session.folderScan?.sourceSnapshot?.isComplete == true
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func i331AppColdHomeHidesControls() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let (controller, _) = try await issue331Controller(base)
    defer { controller.window?.close() }
    let views = try Issue331Views(controller)
    try await issue331Wait("cold Home") {
        controller.session.imageStatus == .empty && !views.state.isHidden && views.shell.isHidden
    }
    #expect(views.state.buttons.map { $0.accessibilityIdentifier() } == ["state.open"])
    views.expectHome("cold launch")
}

@Test(.timeLimit(.minutes(3))) @MainActor func i331AppOpenImageShowsControlsAndReturnHomeHidesThem() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let image = try issue331Image(in: base.appendingPathComponent("Trip"))
    defer { try? FileManager.default.removeItem(at: base) }
    let (controller, _) = try await issue331Controller(base)
    defer { controller.window?.close() }
    let views = try Issue331Views(controller)
    try await issue331Wait("cold Home") { controller.session.imageStatus == .empty && !views.state.isHidden }
    views.expectHome("before opening")
    try await issue331Open(controller, views, image)
    views.expectControls("one image open")
    controller.session.cancelImageOpening()
    try await issue331Wait("back on the Home", detail: { "status \(controller.session.imageStatus)" }) {
        controller.session.imageStatus == .empty && !views.state.isHidden &&
            views.state.buttons.first?.accessibilityIdentifier() == "state.open"
    }
    views.expectHome("back on the Home")
}

@Test(.timeLimit(.minutes(3))) @MainActor func i331AppTwoControllersDecideIndependently() async throws {
    let baseA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let baseB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: baseA, withIntermediateDirectories: true)
    let image = try issue331Image(in: baseB.appendingPathComponent("Trip"))
    defer { try? FileManager.default.removeItem(at: baseA); try? FileManager.default.removeItem(at: baseB) }
    let (a, _) = try await issue331Controller(baseA)
    let (b, _) = try await issue331Controller(baseB)
    defer { a.window?.close(); b.window?.close() }
    let viewsA = try Issue331Views(a), viewsB = try Issue331Views(b)
    try await issue331Open(b, viewsB, image)
    viewsB.expectControls("window B shows an image")
    viewsA.expectHome("window A stays on the Home")
}

/// Characterization: the menu commands whose controls the Home hides were already disabled there.
@Test(.timeLimit(.minutes(3))) @MainActor func i331AppHomeDisablesNavigationAndZoomCommands() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let (controller, _) = try await issue331Controller(base)
    defer { controller.window?.close() }
    let views = try Issue331Views(controller)
    try await issue331Wait("cold Home") { controller.session.imageStatus == .empty && !views.state.isHidden }
    for command in [CommandID.previous, .next, .zoomIn, .zoomOut, .fit, .actualPixels] {
        #expect(!controller.session.isEnabled(command), "\(command) stays disabled on the Home")
    }
}

/// Characterization: a folder still opens to the Grid, where the presentation hides the viewer overlay.
@Test(.timeLimit(.minutes(3))) @MainActor func i331AppFolderLandsOnGridWithOverlayHidden() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trip = base.appendingPathComponent("Trip")
    _ = try issue331Image(in: trip)
    defer { try? FileManager.default.removeItem(at: base) }
    let (controller, root) = try await issue331Controller(base)
    defer { controller.window?.close() }
    let views = try Issue331Views(controller)
    controller.browseRecoveredFolder(trip, rootID: root)
    try await issue331Wait("grid", detail: { "shellHidden \(views.shell.isHidden) mode \(controller.session.mode)" }) {
        !views.shell.isHidden && controller.session.folderScan?.sourceSnapshot?.isComplete == true
    }
    #expect(views.chrome.isHiddenOrHasHiddenAncestor, "the Grid shows no viewer controls")
}
