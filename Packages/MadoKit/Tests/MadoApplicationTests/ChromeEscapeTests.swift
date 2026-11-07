import Testing
import MadoCore
import MadoApplication

// GREEN-only: the existing one-Esc branch already handles the new tools focus context.
@Test @MainActor func chromeEscapeConsumesMenuThenFocusThenRealOrigin() {
    let effects = FakeSessionHost()
    let chrome = ChromeRecallHost()
    let session = ViewerSession(host: effects)
    session.chromeHost = chrome
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    #expect(!router.route(.escape, from: .key, to: session))
    session.tab(reverse: false)
    #expect(session.inspectorFocus.focus == .tools)
    session.setMenuTracking(true)
    #expect(!router.route(.escape, from: .key, to: session))
    #expect(session.inspectorFocus.focus == .tools)
    session.setMenuTracking(false)
    #expect(router.route(.escape, from: .key, to: session))
    #expect(effects.focus == .canvas)
    #expect(session.mode == .viewing)
    #expect(session.previewSet == nil)
    #expect(!router.route(.escape, from: .key, to: session))
    let items = sessionItems()
    session.beginBrowsing(items: items, sourceVersion: .init(1), scrollAnchor: items[1])
    session.select(items[1])
    let selection = session.selection
    router.route(.preview, from: .key, to: session)
    session.tab(reverse: false)
    #expect(router.route(.escape, from: .key, to: session))
    #expect(session.inspectorFocus.focus == .canvas)
    #expect(session.mode == .viewing)
    #expect(session.previewSet != nil)
    #expect(router.route(.escape, from: .key, to: session))
    #expect(session.mode == .browsing)
    #expect(session.selection == selection)
    #expect(session.scrollAnchor == items[1])
}
