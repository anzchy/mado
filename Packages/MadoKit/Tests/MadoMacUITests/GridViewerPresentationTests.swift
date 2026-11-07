import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func issue136InspectorSharesWindowWithViewerAndGrid() {
    _ = NSApplication.shared
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 960, height: 612),
                             preferencesStore: InMemoryDisplayPreferencesStore())
    let canvas = NSView(frame: host.bounds), chrome = NSView(frame: host.bounds)
    let state = NSView(frame: host.bounds), grid = NSView(), inspector = NSView()
    for view in [canvas, shell, state, chrome, inspector] { host.addSubview(view) }
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state,
        grid: grid, inspector: inspector, shell: shell)
    presentation.showViewer()
    presentation.layoutInspector(visible: true)
    #expect(canvas.frame.width == 765)
    #expect(state.frame.width == 765)
    #expect(chrome.frame.width == 765)
    #expect(inspector.frame.minX == canvas.frame.maxX)
    #expect(canvas.frame.union(inspector.frame) == host.bounds)
    presentation.showGrid(reading: false)
    presentation.layoutInspector(visible: true)
    #expect(shell.frame.width == 765)
    #expect(inspector.frame.minX == shell.frame.maxX)
    #expect(inspector.frame.minY == host.bounds.minY)
    #expect(inspector.frame.maxY == host.bounds.maxY)
    #expect(shell.frame.union(inspector.frame) == host.bounds)
    #expect(presentation.showReadingOverGrid(true))
    #expect(inspector.isHidden)
    #expect(shell.frame.width == host.bounds.width)
    #expect(shell.frame.maxX == host.bounds.maxX)
    presentation.showGrid(reading: false)
    presentation.layoutInspector(visible: true)
    #expect(shell.frame.union(inspector.frame) == host.bounds)
    host.frame.size = NSSize(width: 700, height: 520)
    presentation.layoutInspector(visible: true)
    #expect(shell.frame.width == 700) // narrow design overlays the panel
    #expect(canvas.frame.width == 700)
    #expect(inspector.frame == NSRect(x: 480, y: 38, width: 220, height: 395))
    presentation.layoutInspector(visible: false)
    #expect(shell.frame.width == 700)
    presentation.showViewer()
    presentation.layoutInspector(visible: false)
    #expect(canvas.frame.width == 700)
    // Pages 16/34: a presentation without a Grid shell still sizes its Reading State to the stage.
    let bare = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state,
        grid: grid, inspector: inspector)
    bare.layoutInspector(visible: true)
    #expect(state.frame == NSRect(x: 0, y: 0, width: 700, height: 520))
}

@Test @MainActor func cancelReadingRestoresVisibleViewerForFolderNavigatedImage() {
    _ = NSApplication.shared
    let canvas = NSView(), chrome = NSView(), state = NSView(), grid = NSView(), inspector = NSView()
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state, grid: grid, inspector: inspector)
    func expectViewer(_ label: String) {
        #expect(!canvas.isHidden, "\(label): canvas")
        #expect(!chrome.isHidden, "\(label): chrome")
        #expect(!state.isHidden && !state.isAccessibilityHidden(), "\(label): state host")
        #expect(grid.isHidden && grid.isAccessibilityHidden(), "\(label): grid")
        #expect(!presentation.isGridVisible)
    }
    presentation.showViewer()
    expectViewer("viewer")
    inspector.isHidden = false
    presentation.showGrid(reading: true)
    #expect(canvas.isHidden && chrome.isHidden && inspector.isHidden)
    #expect(grid.isHidden && grid.isAccessibilityHidden())
    #expect(!state.isHidden && !state.isAccessibilityHidden())

    presentation.show(.viewer(URL(fileURLWithPath: "/root/A/b.png")))
    expectViewer("cancel to viewer")
    #expect(inspector.isHidden)

    presentation.showGrid(reading: false)
    presentation.show(.viewer(URL(fileURLWithPath: "/root/A/b.png")))
    expectViewer("grid to viewer")
    presentation.showGrid(reading: true)
    presentation.show(.grid)
    #expect(presentation.isGridVisible && !grid.isAccessibilityHidden())
    #expect(state.isHidden && state.isAccessibilityHidden() && canvas.isHidden && chrome.isHidden)
    presentation.showGrid(reading: true)
    presentation.show(.empty)
    expectViewer("cancel to empty")
}

@Test @MainActor func p204R4ShowReadingOverGridOnlyWhenGridVisible() {
    _ = NSApplication.shared
    let canvas = NSView(), chrome = NSView(), state = NSView(), grid = NSView(), inspector = NSView()
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state, grid: grid, inspector: inspector)
    presentation.showViewer()
    #expect(!presentation.showReadingOverGrid(true))
    #expect(!canvas.isHidden && grid.isHidden && !state.isHidden)
    presentation.showGrid(reading: false)
    #expect(!presentation.showReadingOverGrid(false))
    #expect(presentation.isGridVisible && state.isHidden)
    #expect(presentation.showReadingOverGrid(true))
    #expect(grid.isHidden && grid.isAccessibilityHidden())
    #expect(!state.isHidden && !state.isAccessibilityHidden() && canvas.isHidden && chrome.isHidden)
}

@Test @MainActor func gridReadingStaysInsideShellAndViewerRestoresFullStateFrame() {
    _ = NSApplication.shared
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    let store = InMemoryDisplayPreferencesStore()
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772), preferencesStore: store)
    let session = ViewerSession()
    let canvas = NSView(), chrome = NSView(), state = ViewerStateHost(frame: host.bounds, session: session)
    let grid = NSView(), inspector = NSView()
    host.addSubview(canvas)
    host.addSubview(shell)
    host.addSubview(state, positioned: .above, relativeTo: shell)
    host.addSubview(chrome, positioned: .above, relativeTo: state)
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state,
                                               grid: grid, inspector: inspector, shell: shell)
    presentation.showGrid(reading: false)
    #expect(!shell.sidebar.isHidden)
    #expect(presentation.showReadingOverGrid(true))
    state.display(.readingFolder)
    #expect(!shell.isHidden)
    #expect(grid.isHidden && !state.isHidden)
    #expect(state.frame == NSRect(x: 196, y: 40, width: 1084, height: 732))
    let title = state.subviews.first { $0.accessibilityIdentifier() == "state.folder-title" }
    let subtitle = state.subviews.first { $0.accessibilityIdentifier() == "state.folder-subtitle" }
    #expect(title != nil && subtitle != nil && state.buttons.count == 1)
    if let title, let subtitle, let cancel = state.buttons.first {
        #expect(abs(title.frame.midX - state.bounds.midX) < 0.1)
        #expect(abs(subtitle.frame.midX - state.bounds.midX) < 0.1)
        #expect(abs(cancel.frame.midX - state.bounds.midX) < 0.1)
        #expect(state.bounds.contains(title.frame) && state.bounds.contains(subtitle.frame))
    }
    let stacking = host.subviews.map(ObjectIdentifier.init)
    shell.resizeSidebar(to: 320)
    #expect(state.frame == NSRect(x: 320, y: 40, width: 960, height: 732))
    presentation.show(.grid)
    #expect(!grid.isHidden && state.isHidden && !shell.isHidden)
    #expect(!shell.sidebar.isHidden)
    #expect(presentation.showReadingOverGrid(true))
    #expect(state.frame == NSRect(x: 320, y: 40, width: 960, height: 732))
    if let cancel = state.buttons.first { #expect(abs(cancel.frame.midX - state.bounds.midX) < 0.1) }
    presentation.showViewer()
    #expect(shell.isHidden)
    #expect(state.frame == host.bounds)
    #expect(host.subviews.map(ObjectIdentifier.init) == stacking)
    shell.frame.size.width = 800
    shell.layoutSubtreeIfNeeded()
    #expect(state.frame == host.bounds)
}
