import Testing
import MadoCore
import MadoApplication

@MainActor final class FakeSessionHost: ViewerSessionHost {
    var hasImage = true
    var zoom = 1
    var lastEntry: CommandEntry?
    var lastCanvasCommand: CommandID?
    var opens = 0
    var focus: FocusContext = .canvas
    var inspector = false
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {
        lastEntry = entry
        lastCanvasCommand = command
        if command == .zoomIn { zoom += 1 }
    }
    func requestOpen() { opens += 1 }
    func applyFocus(_ focus: FocusContext) { self.focus = focus }
    func showInspector(_ visible: Bool) { inspector = visible }
}

@Test(.timeLimit(.minutes(2))) @MainActor func sessionRouterPreviewAndEscape() {
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    let host = FakeSessionHost()
    let session = ViewerSession(host: host)
    let ids = sessionItems()
    #expect(session.mode == .viewing)
    #expect(session.previewSet == nil)
    #expect(!router.route(.escape, from: .key, to: session))
    for entryCommand: CommandID in [.preview, .enter] {
        session.beginBrowsing(items: ids, sourceVersion: .init(42), scrollAnchor: ids[1])
        session.select(ids[2])
        #expect(router.route(entryCommand, from: .key, to: session))
        #expect(session.mode == .viewing)
        #expect(session.previewSet?.itemIDs == ids)
        #expect(session.previewSet?.sourceVersion == .init(42))
        #expect(session.currentItemID == ids[2])
        #expect(router.route(.next, from: .key, to: session))
        #expect(session.currentItemID == ids[3])
        #expect(router.route(.previous, from: .key, to: session))
        #expect(session.currentItemID == ids[2])
        for _ in 0..<6 { router.route(.next, from: .key, to: session) }
        #expect(session.currentItemID == ids[4])
        for _ in 0..<6 { router.route(.previous, from: .key, to: session) }
        #expect(session.currentItemID == ids[0])
        #expect(router.route(.inspector, from: .key, to: session))
        session.tab(reverse: false)
        session.setMenuTracking(true)
        #expect(!router.route(.escape, from: .key, to: session))
        #expect(session.mode == .viewing)
        #expect(session.inspectorFocus.focus == .textInput)
        session.setMenuTracking(false)
        #expect(router.route(.escape, from: .key, to: session))
        #expect(session.mode == .viewing)
        #expect(session.inspectorFocus.focus == .canvas)
        #expect(session.inspectorFocus.isVisible)
        #expect(router.route(.escape, from: .key, to: session))
        #expect(session.mode == .browsing)
        // #492 owner 2026-11-04: a single pick transfers to the last viewed image.
        #expect(session.selection.selectedItemIDs == [ids[0]])
        #expect(session.selection.anchorItemID == ids[0])
        #expect(session.currentItemID == ids[0])
        #expect(session.scrollAnchor == ids[0])
        router.route(.inspector, from: .key, to: session)
    }
    // Independent restore oracle: known scroll anchor ids[1] is removed while viewing.
    session.beginBrowsing(items: ids, sourceVersion: .init(42), scrollAnchor: ids[1])
    session.select(ids[2])
    session.select(ids[4], modifier: .command)
    #expect(router.route(.preview, from: .key, to: session))
    #expect(session.previewSet?.itemIDs == [ids[2], ids[4]])
    #expect(session.currentItemID == ids[4])
    session.updateItems(ids + sessionItems(1), sourceVersion: .init(43))
    #expect(session.previewSet?.itemIDs == [ids[2], ids[4]])
    session.updateItems([ids[0], ids[2]], sourceVersion: .init(44))
    #expect(session.currentItemID == ids[2])
    #expect(router.route(.escape, from: .key, to: session))
    #expect(session.selection.selectedItemIDs == [ids[2]])
    #expect(session.selection.currentItemID == nil)
    #expect(session.selection.anchorItemID == nil)
    // Actual Esc restores the reconciled origin, with the deleted scroll anchor cleared.
    #expect(session.scrollAnchor == nil)
    session.select(ids[0], modifier: .command)
    session.select(ids[0], modifier: .command)
    router.route(.enter, from: .key, to: session)
    #expect(session.previewSet?.itemIDs == [ids[0], ids[2]])
    #expect(session.currentItemID == ids[0])
    session.updateItems([], sourceVersion: .init(45))
    #expect(session.currentItemID == nil)
    router.route(.escape, from: .key, to: session)
    #expect(session.selection == BrowserSelection())
    #expect(!router.route(.preview, from: .key, to: session))
    #expect(!router.route(.next, from: .key, to: session))
    #expect(!router.route(.previous, from: .key, to: session))
    #expect(!router.route(.search, from: .key, to: session))
}

@Test(.timeLimit(.minutes(2))) @MainActor func sessionChromeLocksAndWindowIsolation() {
    let clock = FakeViewerClock()
    let store = InMemoryDisplayPreferencesStore()
    let host = FakeSessionHost()
    let first = ViewerSession(preferencesStore: store, clock: clock, host: host)
    let second = ViewerSession(preferencesStore: store, clock: clock)
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    let ids = sessionItems()
    first.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    first.select(ids[1])
    router.route(.preview, from: .key, to: first)
    #expect(second.selection.selectedItemIDs.isEmpty)
    #expect(second.previewSet == nil)
    #expect(second.inspectorFocus.focus == .canvas)
    clock.now = 2.5
    first.advanceChrome()
    second.advanceChrome()
    #expect(first.chrome.visibility == .hidden)
    #expect(second.chrome.visibility == .hidden)
    first.setMenuTracking(true)
    #expect(first.chrome.visibility == .locked([.menu]))
    #expect(second.chrome.visibility == .hidden)
    #expect(first.nextHideDeadline == nil)
    clock.now = 10
    first.setMenuTracking(false)
    #expect(first.nextHideDeadline == 12.5)
    router.route(.inspector, from: .button, to: first)
    #expect(first.chrome.visibility == .locked([.inspector]))
    #expect(!second.inspectorFocus.isVisible)
    first.tab(reverse: false)
    #expect(first.chrome.visibility == .locked([.inspector, .keyboardFocus]))
    first.tab(reverse: true)
    #expect(first.chrome.visibility == .locked([.inspector]))
    first.updateFocus(.panel)
    #expect(first.chrome.locks == [.inspector, .keyboardFocus])
    router.route(.escape, from: .key, to: first)
    #expect(first.chrome.locks == [.inspector])
    clock.now = 20
    router.route(.inspector, from: .button, to: first)
    #expect(first.nextHideDeadline == 22.5)
    #expect(second.nextHideDeadline == nil)
    store.value.filmstripExpanded = true
    #expect(first.chrome.visibility == .locked([.filmstrip]))
    #expect(second.chrome.visibility == .locked([.filmstrip]))
    clock.now = 30
    store.value.filmstripExpanded = false
    clock.now = 31
    #expect(first.nextHideDeadline == 32.5)
    #expect(second.nextHideDeadline == 32.5)
    store.value.alwaysShowTools = true
    #expect(first.chrome.visibility == .pinned)
    #expect(second.chrome.visibility == .pinned)
    clock.now = 100
    first.advanceChrome()
    #expect(first.chrome.visibility == .pinned)
    store.value.alwaysShowTools = false
    #expect(first.nextHideDeadline == 102.5)
    first.activity()
    clock.now = 101
    first.activity()
    #expect(first.nextHideDeadline == 103.5)
    #expect(second.nextHideDeadline == 102.5)
    #expect(first.selection.selectedItemIDs == [ids[1]])
    #expect(first.previewSet?.itemIDs == ids)
    #expect(second.previewSet == nil)
    let initial = ViewerSession(preferencesStore: InMemoryDisplayPreferencesStore(
        .init(alwaysShowTools: true, filmstripExpanded: true)), clock: clock)
    #expect(initial.chrome.visibility == .locked([.filmstrip]))
    #expect(initial.displayPreferences.alwaysShowTools)
}

@Test(.timeLimit(.minutes(2))) @MainActor func sessionContextTargetSurvivesSelectionChange() {
    let session = ViewerSession()
    let ids = sessionItems()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    session.select(ids[3])
    session.select(ids[1], modifier: .command)
    let target = session.contextMenuTarget(for: ids[3])
    session.select(ids[0])
    #expect(session.currentItemID == ids[0])
    #expect(session.resolve(target) == [ids[1], ids[3]])
    session.updateItems([ids[0], ids[3]], sourceVersion: .init(2))
    #expect(session.resolve(target) == [ids[3]])
}
