import Testing
import MadoCore
import MadoApplication

@Test @MainActor func issue349ThumbnailCommandsFollowFiniteStateModel() {
    let router = CommandRouter()
    let root = AccessRootID()
    let ids = (0..<4).map { ItemID.rootRelative(rootID: root, relativePath: "\($0).jpg") }
    for start in stride(from: 140.0, through: 280, by: 10) {
        var initial = DisplayPreferences(alwaysShowTools: true, appearance: .dark, gridSidebarWidth: 284)
        initial.thumbnailSize = start
        initial.showFileNames = false
        initial.thumbnailFit = .fit
        initial.folderSort = .size
        initial.loopThroughImages = true
        let store = InMemoryDisplayPreferencesStore(initial)
        let session = ViewerSession(preferencesStore: store)
        let second = ViewerSession(preferencesStore: store)
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[1])
        session.select(ids[1]); session.select(ids[3], modifier: .command)
        let selection = session.selection
        let zoom = session.zoomMode
        var expected = initial
        let sequence: [CommandID] = [.zoomIn, .zoomOut] + Array(repeating: .zoomIn, count: 10)
            + Array(repeating: .zoomOut, count: 10) + [.actualPixels, .actualPixels]
        for command in sequence {
            expected.thumbnailSize = command == .zoomIn ? min(280, expected.thumbnailSize + 20)
                : command == .zoomOut ? max(140, expected.thumbnailSize - 20) : 220
            #expect(router.route(command, from: .key, to: session, commandModified: true))
            #expect(store.value == expected, "start \(start), command \(command)")
            #expect(session.displayPreferences == expected)
            #expect(second.displayPreferences == expected)
            #expect(session.selection == selection)
            #expect(session.scrollAnchor == ids[1])
            #expect(session.zoomMode == zoom)
        }
    }
}

@Test @MainActor func issue349ThumbnailCommandsRejectBareFitAndFocusedInput() {
    let router = CommandRouter()
    let store = InMemoryDisplayPreferencesStore()
    let host = FakeSessionHost()
    let session = ViewerSession(preferencesStore: store, host: host)
    let item = ItemID.rootRelative(rootID: AccessRootID(), relativePath: "a.jpg")
    session.beginBrowsing(items: [item], sourceVersion: .init(1), scrollAnchor: item)
    for entry in CommandEntry.allCases {
        for command: CommandID in [.fit, .actualPixels, .zoomIn, .zoomOut] {
            #expect(!router.route(command, from: entry, to: session))
            #expect(store.value.thumbnailSize == 220)
        }
        #expect(!router.route(.fit, from: entry, to: session, commandModified: true))
    }
    session.setInspectorVisible(true)
    session.updateFocus(.textInput)
    for entry: CommandEntry in [.key, .menu] {
        for command: CommandID in [.actualPixels, .zoomIn, .zoomOut] {
            #expect(!router.route(command, from: entry, to: session, commandModified: true))
            #expect(store.value.thumbnailSize == 220)
        }
    }
    session.updateFocus(.canvas)
    #expect(router.route(.zoomIn, from: .menu, to: session, commandModified: true))
    #expect(store.value.thumbnailSize == 240)
    session.setMenuTracking(true)
    #expect(!router.route(.zoomOut, from: .key, to: session, commandModified: true))
    #expect(store.value.thumbnailSize == 240)
    #expect(host.lastCanvasCommand == nil, "Grid never sends thumbnail commands to image canvas")
}

@Test @MainActor func issue349ThumbnailCommandsLeaveViewerZoomUnchanged() {
    let router = CommandRouter()
    var preferences = DisplayPreferences()
    preferences.thumbnailSize = 170
    let store = InMemoryDisplayPreferencesStore(preferences)
    let host = FakeSessionHost()
    let session = ViewerSession(preferencesStore: store, host: host)
    for modified in [false, true] {
        for command: CommandID in [.fit, .actualPixels, .zoomIn, .zoomOut] {
            #expect(router.route(command, from: .key, to: session, commandModified: modified))
            #expect(host.lastCanvasCommand == command)
            #expect(store.value == preferences)
        }
    }
}
