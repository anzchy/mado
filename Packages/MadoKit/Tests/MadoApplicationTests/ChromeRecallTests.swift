import Testing
import MadoCore
import MadoApplication

@MainActor final class ChromeRecallHost: ViewerChromeHost {
    var visible = false
    var lights = false
    var focusResult = true
    var recalls: [(Bool, Bool, Bool)] = []
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {
        visible = toolsVisible; lights = trafficLightsVisible
    }
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool {
        recalls.append((visible, reverse, entering)); return focusResult
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeRecallRegionsTabLoopAndFocusLock() {
    let clock = FakeViewerClock()
    let host = ChromeRecallHost()
    let session = ViewerSession(clock: clock)
    session.chromeHost = host
    #expect(host.visible)
    clock.now = 2.5; session.advanceChrome()
    #expect(!host.visible && !host.lights)
    session.pointerMoved(in: .canvas)
    #expect(session.chrome.visibility == .hidden)
    session.pointerMoved(in: .top)
    #expect(session.chrome.visibility == .hidden)
    #expect(host.lights)
    session.pointerMoved(in: .outside)
    #expect(!host.lights)
    session.pointerMoved(in: .bottom)
    #expect(session.chrome.visibility == .visible)
    #expect(session.nextHideDeadline == 5)
    clock.now = 5; session.advanceChrome()
    session.tab(reverse: false)
    #expect(host.recalls.count == 1)
    #expect(host.recalls.first?.0 == true)
    #expect(host.recalls.first?.1 == false)
    #expect(host.recalls.first?.2 == true)
    #expect(session.inspectorFocus.focus == .tools)
    #expect(session.chrome.visibility == .locked([.keyboardFocus]))
    clock.now = 100; session.advanceChrome()
    #expect(host.visible)
    host.focusResult = false
    session.tab(reverse: false)
    #expect(session.inspectorFocus.focus == .canvas)
    #expect(session.nextHideDeadline == 102.5)
    host.focusResult = true
    session.tab(reverse: true)
    #expect(host.recalls.last?.1 == true)
    #expect(host.recalls.last?.2 == true)
    #expect(session.inspectorFocus.focus == .tools)
    session.setInspectorVisible(true)
    host.focusResult = false
    session.tab(reverse: false)
    #expect(session.inspectorFocus.focus == .textInput)
    host.focusResult = true
    session.tab(reverse: true)
    #expect(session.inspectorFocus.focus == .tools)
    host.focusResult = false
    session.tab(reverse: true)
    #expect(session.inspectorFocus.focus == .canvas)
    session.updateFocus(.textInput)
    session.tab(reverse: false)
    #expect(session.inspectorFocus.focus == .canvas)
}
