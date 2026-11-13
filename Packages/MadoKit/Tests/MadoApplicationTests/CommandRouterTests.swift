import Testing
import MadoCore
import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func commandRouting() {
    let router = CommandRouter()
    let firstHost = FakeSessionHost()
    let secondHost = FakeSessionHost()
    let first = ViewerSession(host: firstHost)
    let second = ViewerSession(host: secondHost)
    for entry in CommandEntry.allCases {
        firstHost.zoom = 1
        #expect(router.route(.zoomIn, from: entry, to: first))
        #expect(firstHost.zoom == 2)
        #expect(firstHost.lastEntry == entry)
        #expect(secondHost.zoom == 1)
        firstHost.hasImage = false
        #expect(!router.route(.zoomIn, from: entry, to: first))
        #expect(firstHost.zoom == 2)
        firstHost.hasImage = true
        #expect(!router.route(.preview, from: entry, to: first))
    }
    #expect(router.route(.zoomIn, from: .key, to: second))
    #expect(secondHost.zoom == 2)
    #expect(firstHost.zoom == 2)
    first.setInspectorVisible(true)
    first.updateFocus(.textInput)
    for id: CommandID in [.preview, .previous, .next, .enter, .fit, .actualPixels, .zoomIn, .zoomOut] {
        #expect(!router.route(id, from: .key, to: first))
    }
    #expect(firstHost.zoom == 2)
    // Command-modified Inspector works while editing; showing also preserves the original visible assertion.
    #expect(router.route(.inspector, from: .key, to: first))
    #expect(!first.inspectorFocus.isVisible)
    #expect(!firstHost.inspector)
    #expect(router.route(.inspector, from: .key, to: first))
    #expect(first.inspectorFocus.isVisible)
    #expect(firstHost.inspector)
    first.updateFocus(.textInput)
    #expect(router.route(.zoomIn, from: .button, to: first))
    #expect(firstHost.zoom == 3)
    first.updateFocus(.panel)
    #expect(router.route(.zoomIn, from: .menu, to: first))
    #expect(firstHost.zoom == 4)
    first.setMenuTracking(true)
    #expect(!router.route(.escape, from: .key, to: first))
    #expect(first.inspectorFocus.focus == .panel)
    #expect(!router.route(.zoomIn, from: .key, to: first))
    #expect(firstHost.zoom == 4)
    #expect(!router.route(.escape, from: .menu, to: first))
    first.setMenuTracking(false)
    #expect(router.route(.escape, from: .key, to: first))
    #expect(first.inspectorFocus.focus == .canvas)
    #expect(firstHost.focus == .canvas)
    for id: CommandID in [.fit, .actualPixels, .zoomOut] {
        #expect(router.route(id, from: .button, to: first))
        #expect(firstHost.lastCanvasCommand == id)
    }
    #expect(router.route(.open, from: .menu, to: first))
    #expect(firstHost.opens == 1)
    #expect(secondHost.opens == 0)
}

/// #348: a ⌘ zoom key resolves to the bare key's command, so key entry still yields to a text field.
@Test(.timeLimit(.minutes(2))) @MainActor func cmdZoomKeyEntryBlockedInTextInput() {
    let router = CommandRouter()
    let host = FakeSessionHost()
    let session = ViewerSession(host: host)
    session.setInspectorVisible(true) // Text input lives in the Inspector.
    #expect([CommandID.fit, .actualPixels, .zoomIn, .zoomOut].allSatisfy { !$0.usesCommand })
    let cases: [(String, CommandID)] = [("0", .actualPixels), ("9", .fit), ("+", .zoomIn), ("=", .zoomIn),
                                        ("-", .zoomOut), ("−", .zoomOut)]
    for (key, expected) in cases {
        #expect(CommandID.matching(key: key, command: true) == expected, "⌘\(key)")
        session.updateFocus(.canvas)
        host.lastCanvasCommand = nil
        #expect(router.route(expected, from: .key, to: session))
        #expect(host.lastCanvasCommand == expected)
        host.lastCanvasCommand = nil
        session.updateFocus(.textInput)
        let zoom = host.zoom
        #expect(!router.route(expected, from: .key, to: session), "⌘\(key) in a text field")
        #expect(host.lastCanvasCommand == nil)
        #expect(host.zoom == zoom)
        #expect(router.route(expected, from: .button, to: session))
        #expect(host.lastCanvasCommand == expected)
    }
}
