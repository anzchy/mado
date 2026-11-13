import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class GridChromeClock: ViewerClock { var now: TimeInterval = 0 }

@MainActor private final class GridChromeSessionHost: ViewerSessionHost {
    var hasImage = true
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() {}
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridChromeKeepsTitlebarVisibleAcrossDeadlineAndViewerRoundTrip() {
    _ = NSApplication.shared
    let clock = GridChromeClock(), session = ViewerSession(clock: clock, host: GridChromeSessionHost())
    let router = CommandRouter()
    let item = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [item], sourceVersion: .init(1), scrollAnchor: item)
    session.select(item)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    func applyPolicy() {
        ChromeTitlebarPolicy.apply(to: window,
            visible: ChromeTitlebarPolicy.trafficLightsVisible(
                isGridVisible: session.mode == .browsing, viewerVisible: session.trafficLightsVisible),
            fullScreen: false)
    }
    clock.now = 2.5
    session.advanceChrome()
    applyPolicy()
    #expect(session.chrome.isHidden)
    #expect(window.titleVisibility == .visible)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
    #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
    #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)

    #expect(router.route(.preview, from: .key, to: session))
    applyPolicy()
    #expect(session.mode == .viewing)
    #expect(window.titleVisibility == .visible)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
    clock.now = 5
    session.advanceChrome()
    applyPolicy()
    #expect(window.titleVisibility == .hidden)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == true)

    #expect(router.route(.escape, from: .key, to: session))
    applyPolicy()
    #expect(session.mode == .browsing)
    #expect(window.titleVisibility == .visible)
    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
}
