import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
@testable import PicseeMacUI

/// #313 (spec #311): 「只有未打开文件夹的窗口没有底栏」. One window's views as CanvasWindowController composes them;
/// GridViewerPresentation decides which surface the window shows.
@MainActor private final class BarPresenceScene {
    let session = ViewerSession()
    let window: NSWindow
    let content = NSView()
    let canvas: CanvasView
    let shell: GridShellView
    let grid: GridBrowserView
    let state: ViewerStateHost
    let chrome: ViewerChromeOverlay
    let inspector = NSView()
    let presentation: GridViewerPresentation
    init() {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.frame = frame
        canvas = CanvasView(frame: frame, session: session)
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              preferencesStore: InMemoryDisplayPreferencesStore())
        shell.isHidden = true
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        state = ViewerStateHost(frame: frame, session: session)
        chrome = ViewerChromeOverlay(frame: frame, session: session)
        content.addSubview(canvas)
        content.addSubview(shell)
        shell.mainContent.addSubview(grid)
        content.addSubview(state, positioned: .above, relativeTo: shell)
        content.addSubview(inspector, positioned: .above, relativeTo: state)
        content.addSubview(chrome, positioned: .above, relativeTo: inspector)
        window.contentView = content
        presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state, grid: grid,
                                              inspector: inspector, shell: shell)
        state.subviews.compactMap { $0 as? FirstLaunchView }.first?.pinAccessibility()
    }
    var barShown: Bool { !shell.footer.isHiddenOrHasHiddenAncestor && shell.footer.frame.height == 40 }
    var sidebarShown: Bool { !shell.sidebar.isHiddenOrHasHiddenAncestor }
    /// The bar in window coordinates, or nil when it is not on screen.
    var barFrame: NSRect? { barShown ? shell.footer.convert(shell.footer.bounds, to: nil) : nil }
    func layout() { presentation.layoutInspector(visible: false); content.layoutSubtreeIfNeeded() }
    func folder(_ names: [String]) -> FolderSnapshot {
        pinningSnapshot(count: names.count, folder: URL(fileURLWithPath: "/tmp/i313-bar"), names: names)
    }
}

@MainActor private func expectHome(_ scene: BarPresenceScene, _ stage: String) {
    #expect(!scene.barShown, "\(stage): the Home shows no Bottom Bar")
    #expect(!scene.sidebarShown, "\(stage): the Home shows no sidebar")
    #expect(scene.shell.isHidden, "\(stage): the grid shell is not on the Home")
    #expect(!scene.state.isHidden && scene.state.frame == scene.content.bounds,
            "\(stage): the Home fills the window, not the shell's main frame")
}

@MainActor private func expectBar(_ scene: BarPresenceScene, _ stage: String) {
    #expect(scene.barShown, "\(stage): a window with a folder open shows the Bottom Bar")
    #expect(scene.barFrame == NSRect(x: 0, y: 0, width: 1280, height: 40), "\(stage): bar frame \(String(describing: scene.barFrame))")
    // 「和网格一起直接出现」: no animation of its own.
    for view in [scene.shell, scene.shell.footer] {
        #expect(view.alphaValue == 1, "\(stage): \(view.accessibilityIdentifier()) alpha \(view.alphaValue)")
        #expect(view.layer?.animationKeys()?.isEmpty ?? true,
                "\(stage): \(view.accessibilityIdentifier()) animates \(view.layer?.animationKeys() ?? [])")
    }
}

@Test @MainActor func i313HomeHasNoBottomBarOrSidebar() {
    let scene = BarPresenceScene()
    defer { scene.window.close() }
    scene.presentation.showViewer()
    scene.state.display(.empty)
    scene.layout()
    #expect(scene.state.textLines.contains("Drop a photo folder here"))
    expectHome(scene, "cold launch")
}

@Test @MainActor func i313EveryFolderStateShowsTheBottomBarInTheSamePass() {
    let scene = BarPresenceScene()
    defer { scene.window.close() }
    scene.presentation.showViewer()
    scene.state.display(.empty)
    scene.layout()
    expectHome(scene, "before entry")

    // Reading State: every entry point (button, ⌘O, drag-in, recent item) starts here.
    scene.presentation.showGrid(reading: true)
    scene.state.display(.readingFolder)
    expectBar(scene, "Reading State")
    #expect(scene.sidebarShown, "Reading State keeps the sidebar")

    // Failed read: the failure page sits on the shell's reading surface.
    scene.state.display(.folderScanFailed("Folder scan failed", "Folder"))
    scene.shell.setReadingStatus(false)
    scene.layout()
    expectBar(scene, "failed read")

    // Retry from the failed page reads again on the same surface.
    scene.presentation.resumeReadingFooter(true)
    scene.state.display(.readingFolder)
    scene.layout()
    expectBar(scene, "Retry")

    // Empty folder (page 22).
    scene.presentation.showGrid(reading: false)
    scene.shell.setEmptyFolderState(true, recents: [], now: Date())
    scene.layout()
    #expect(scene.shell.emptyFolderVisible)
    expectBar(scene, "empty folder")
    scene.shell.setEmptyFolderState(false, recents: [], now: Date())

    // Lost Access (page 26): CanvasWindowController.showWaitingAccessState.
    scene.presentation.showGrid(reading: true)
    scene.shell.setReadingStatus(false)
    scene.state.isHidden = true
    let lost = LostAccessStateView(frame: scene.shell.mainContent.bounds)
    scene.shell.mainContent.addSubview(lost, positioned: .above, relativeTo: nil)
    scene.layout()
    #expect(!lost.isHiddenOrHasHiddenAncestor)
    expectBar(scene, "Lost Access")
    lost.removeFromSuperview()

    // Grid.
    let snapshot = scene.folder(["a.png", "b.png"])
    scene.presentation.showCompletedGrid(snapshot, selection: .init(), currentItemID: snapshot.entries[0].itemID,
                                         offset: nil)
    scene.layout()
    expectBar(scene, "Grid")
}

@Test @MainActor func i313ReturningFromTheViewerLeavesTheBottomBarAsItWas() {
    let scene = BarPresenceScene()
    defer { scene.window.close() }
    let snapshot = scene.folder(["a.png", "b.png"])
    scene.presentation.showCompletedGrid(snapshot, selection: .init(), currentItemID: snapshot.entries[1].itemID,
                                         offset: nil)
    scene.layout()
    expectBar(scene, "Grid before preview")
    scene.shell.toggleSidebar()
    scene.shell.setSearchStatus(resultCount: 2, term: "")
    scene.layout()
    let before = (frame: scene.barFrame, sidebar: scene.sidebarShown, toggle: scene.shell.toggleButton.frame,
                  status: scene.shell.searchStatus.stringValue, search: scene.shell.searchAvailable)

    scene.presentation.showViewer()
    scene.layout()
    #expect(!scene.barShown, "the viewer keeps its own command bar")

    scene.presentation.restoreGrid(snapshot, selection: .init(), offset: nil)
    scene.layout()
    expectBar(scene, "return from viewer")
    #expect(scene.barFrame == before.frame)
    #expect(scene.sidebarShown == before.sidebar)
    #expect(scene.shell.toggleButton.frame == before.toggle)
    #expect(scene.shell.searchStatus.stringValue == before.status)
    #expect(scene.shell.searchAvailable == before.search)
}

@Test @MainActor func i313CancellingAnEntryToTheHomeRemovesTheBar() {
    let scene = BarPresenceScene()
    defer { scene.window.close() }
    scene.presentation.showViewer()
    scene.state.display(.empty)
    scene.presentation.showGrid(reading: true)
    scene.state.display(.readingFolder)
    scene.layout()
    expectBar(scene, "Reading State")
    // Cancel Reading with nothing to return to: CanvasWindowController.restoreEmptyFolderEntry.
    scene.presentation.show(.empty)
    scene.state.display(.empty)
    scene.layout()
    expectHome(scene, "after Cancel Reading")
}

@Test @MainActor func i313TwoWindowsDecideTheBarOnTheirOwn() {
    let home = BarPresenceScene(), folder = BarPresenceScene()
    defer { home.window.close(); folder.window.close() }
    home.presentation.showViewer()
    home.state.display(.empty)
    let snapshot = folder.folder(["a.png"])
    folder.presentation.showCompletedGrid(snapshot, selection: .init(), currentItemID: nil, offset: nil)
    home.layout(); folder.layout()
    expectHome(home, "Home window")
    expectBar(folder, "folder window")
    folder.presentation.showGrid(reading: true)
    folder.layout()
    expectHome(home, "Home window while the other reads")
    expectBar(folder, "folder window reading")
}
