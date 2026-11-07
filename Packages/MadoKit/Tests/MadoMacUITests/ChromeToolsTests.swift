import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor final class ChromeToolsHost: ViewerSessionNavigationHost {
    var hasImage = true
    var canNavigate = true
    var entries: [(CommandID, CommandEntry)] = []
    var opened = 0
    var inspections: [Bool] = []
    var navigation: [NavigationDirection] = []
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { entries.append((command, entry)) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? {
        entries.append((command, entry)); return 1.25
    }
    func requestOpen() { opened += 1 }
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) { inspections.append(visible) }
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
}

@Test @MainActor func chromeThreeGroupsRouteAndReflectActualScale() throws {
    _ = NSApplication.shared
    let host = ChromeToolsHost()
    let session = ViewerSession(host: host)
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 960, height: 640), session: session)
    let window = NSWindow(contentRect: overlay.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = overlay
    defer { window.close() }
    #expect(overlay.groups.count == 3)
    // #444, page 14: 侧栏 / 返回网格 / 更多 lead; Open and Inspector stay on their menu items and shortcuts.
    #expect(overlay.tools.map(\.kind) == [.intent(.toggleSidebar), .intent(.returnToGrid), .more, .command(.previous),
        .command(.next), .command(.zoomOut), .command(.actualPixels), .command(.zoomIn)])
    let presenter = RecordingMenuPresenter()
    presenter.choose = 1
    overlay.menuPresenter = presenter
    overlay.refresh(filename: "lake.png", position: "2 / 12")
    #expect(overlay.filename == "lake.png")
    #expect(overlay.position == "2 / 12")
    for tool in overlay.tools { tool.activate() }
    #expect(host.opened == 0 && host.inspections.isEmpty)
    #expect(host.navigation == [.previous, .next])
    #expect(host.entries.map(\.0) == [.zoomOut, .actualPixels, .zoomIn])
    #expect(host.entries.allSatisfy { $0.1 == .button })
    host.hasImage = false; host.canNavigate = false
    overlay.refresh()
    #expect(overlay.filename == nil)
    #expect(overlay.position == nil)
    for tool in overlay.tools.dropFirst(3) { tool.activate() }
    #expect(host.entries.count == 3)
    #expect(host.navigation.count == 2)
    #expect(ScaleIndicator(actualPixels: false) {}.label == "Fit window")
    #expect(ScaleIndicator(actualPixels: true) {}.label == "1:1 · 100%")
    #expect(ScaleIndicator(actualPixels: false, customZoom: 1.25) {}.label == "125%")
    let other = ViewerSession()
    other.advanceChrome()
    #expect(other.inspectorFocus.isVisible == false)
    #expect(other.zoomMode == .fit)
}
