import Testing
import MadoCore
import MadoApplication

@MainActor private final class CanvasZoomHost: ViewerSessionHost {
    let effects = FakeSessionHost()
    var hasImage: Bool { effects.hasImage }
    var finalZoom = 1.25
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { effects.performCanvas(command, from: entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? {
        performCanvas(command, from: entry)
        return finalZoom
    }
    func requestOpen() { effects.requestOpen() }
    func applyFocus(_ focus: FocusContext) { effects.applyFocus(focus) }
    func showInspector(_ visible: Bool) { effects.showInspector(visible) }
}

@Test @MainActor func canvasZoomModeRouterEffectsAndSessionIsolation() {
    let router = CommandRouter()
    let host = CanvasZoomHost()
    let first = ViewerSession(host: host)
    let second = ViewerSession(host: FakeSessionHost())
    #expect(first.zoomMode == .fit)
    for entry in CommandEntry.allCases {
        #expect(router.route(.actualPixels, from: entry, to: first))
        #expect(first.zoomMode == .actualPixels)
        #expect(host.effects.lastCanvasCommand == .actualPixels)
        #expect(host.effects.lastEntry == entry)
        host.finalZoom = 1.25
        #expect(router.route(.zoomIn, from: entry, to: first))
        #expect(first.zoomMode == .custom(1.25))
        #expect(host.effects.lastCanvasCommand == .zoomIn)
        #expect(host.effects.lastEntry == entry)
        host.finalZoom = 0.8
        #expect(router.route(.zoomOut, from: entry, to: first))
        #expect(first.zoomMode == .custom(0.8))
        #expect(host.effects.lastCanvasCommand == .zoomOut)
        #expect(host.effects.lastEntry == entry)
        #expect(router.route(.fit, from: entry, to: first))
        #expect(first.zoomMode == .fit)
        #expect(host.effects.lastCanvasCommand == .fit)
        #expect(host.effects.lastEntry == entry)
    }
    first.reportCanvasZoom(64) // The canvas reports the final value for pinch too.
    #expect(first.zoomMode == .custom(64))
    #expect(second.zoomMode == .fit)
    first.beginCanvasImage()
    #expect(first.zoomMode == .fit)
    host.effects.hasImage = false
    #expect(!router.route(.zoomIn, from: .key, to: first))
    #expect(first.zoomMode == .fit)
}

@Test @MainActor func canvasTwoLiveSessionsKeepIndependentZoom() {
    let firstHost = CanvasZoomHost(), secondHost = CanvasZoomHost()
    let first = ViewerSession(host: firstHost), second = ViewerSession(host: secondHost)
    let router = CommandRouter()
    firstHost.finalZoom = 4
    secondHost.finalZoom = 0.125
    router.route(.zoomIn, from: .key, to: first)
    router.route(.zoomOut, from: .menu, to: second)
    #expect(first.zoomMode == .custom(4))
    #expect(second.zoomMode == .custom(0.125))
    router.route(.actualPixels, from: .button, to: first)
    #expect(first.zoomMode == .actualPixels)
    #expect(second.zoomMode == .custom(0.125))
}
