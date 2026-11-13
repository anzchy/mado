import Foundation
import Testing
import MadoCore
@testable import MadoApplication

/// #444: 返回网格 runs Esc's return path from any focus; 显示侧栏 is allowed only in a viewer entered from a grid.
@MainActor private final class IntentHost: ViewerSessionHost, ViewerSingleImageReturnHost, ViewerChromeHost {
    var hasImage = true
    var canReturnToFolder = false
    var available = false
    var returns = 0, folderReturns = 0
    var intents: [ViewerChromeIntent] = []
    let store: InMemoryDisplayPreferencesStore
    init(store: InMemoryDisplayPreferencesStore) { self.store = store }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() { returns += 1 }
    func returnSingleImageToFolder() { folderReturns += 1 }
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {}
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool { false }
    var viewerSidebarAvailable: Bool { available }
    func performChromeIntent(_ intent: ViewerChromeIntent) {
        intents.append(intent)
    }
}

/// Adopts the chrome host without the #444 members, so the protocol defaults apply.
@MainActor private final class LegacyChromeHost: ViewerSessionHost, ViewerChromeHost {
    var hasImage = true
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {}
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool { false }
}

enum Intent444Source: String, CaseIterable, Sendable { case browsing, preview, single, files }

@MainActor private struct Intent444Fixture {
    let store = InMemoryDisplayPreferencesStore()
    let host: IntentHost
    let session: ViewerSession
    let items: [ItemID]
    let originSelection: BrowserSelection
    init(_ source: Intent444Source, count: Int = 3, selected: Int = 1, anchor: Bool = false,
         canReturnToFolder: Bool = false, available: Bool = false) {
        host = IntentHost(store: store)
        host.canReturnToFolder = canReturnToFolder
        host.available = available
        session = ViewerSession(preferencesStore: store, host: host)
        session.chromeHost = host
        items = (0..<count).map { _ in ItemID.ephemeral(UUID()) }
        session.beginBrowsing(items: items, sourceVersion: .init(1), scrollAnchor: anchor ? items[0] : nil)
        session.select(items[selected])
        originSelection = session.selection
        switch source {
        case .browsing: break
        case .preview: CommandRouter().route(.preview, from: .key, to: session)
        case .single: session.leaveBrowsing()
        case .files:
            session.leaveBrowsing()
            session.filePreviewSet = FilePreviewSet(files: [URL(fileURLWithPath: "/p/a.png"), URL(fileURLWithPath: "/p/b.png")])
        }
    }
}

private func canReturnOracle(_ source: Intent444Source, _ canReturnToFolder: Bool) -> Bool {
    source == .preview || (source == .single && canReturnToFolder)
}

@Test(.timeLimit(.minutes(2)), arguments: Intent444Source.allCases, [false, true])
@MainActor func i444EscapeEnabledEqualsCanReturnToSourceAcrossStates(source: Intent444Source, folder: Bool) {
    for focus in [FocusContext.canvas, .tools] {
        let f = Intent444Fixture(source, canReturnToFolder: folder)
        f.session.updateFocus(focus)
        let oracle = canReturnOracle(source, folder)
        #expect(f.session.canReturnToSource == oracle, "\(source) folder \(folder) focus \(focus)")
        #expect(f.session.isEnabled(.escape) == (focus != .canvas || oracle), "\(source) folder \(folder) focus \(focus)")
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [1, 3, 12], [false, true])
@MainActor func i444ReturnToGridIntentMatchesEscapeAtCanvasFocus(count: Int, anchor: Bool) {
    for selected in Set([0, count / 2, count - 1]) {
        let a = Intent444Fixture(.preview, count: count, selected: selected, anchor: anchor)
        let b = Intent444Fixture(.preview, count: count, selected: selected, anchor: anchor)
        // Mirror the item IDs: b's session gets a's items so the selections compare equal.
        b.session.beginBrowsing(items: a.items, sourceVersion: .init(1), scrollAnchor: anchor ? a.items[0] : nil)
        b.session.select(a.items[selected])
        CommandRouter().route(.preview, from: .key, to: b.session)
        a.session.perform(intent: .returnToGrid)
        CommandRouter().route(.escape, from: .key, to: b.session)
        #expect(a.session.mode == .browsing && b.session.mode == .browsing)
        #expect(a.session.selection == b.session.selection)
        #expect(a.session.selection == a.originSelection)
        #expect(a.session.scrollAnchor == b.session.scrollAnchor)
        #expect(a.session.previewSet == nil && b.session.previewSet == nil)
        #expect(a.session.currentItemID == b.session.currentItemID)
        #expect(a.host.returns == 1 && b.host.returns == 1)
    }
    let a = Intent444Fixture(.single, canReturnToFolder: true)
    let b = Intent444Fixture(.single, canReturnToFolder: true)
    a.session.perform(intent: .returnToGrid)
    CommandRouter().route(.escape, from: .key, to: b.session)
    #expect(a.host.folderReturns == 1 && b.host.folderReturns == 1)
    #expect(a.session.mode == b.session.mode)
}

@Test(.timeLimit(.minutes(2))) @MainActor func i444ReturnToGridIntentFromToolsFocusReturnsWhileEscapeOnlyRefocuses() {
    let x = Intent444Fixture(.preview), y = Intent444Fixture(.preview)
    x.session.updateFocus(.tools); y.session.updateFocus(.tools)
    CommandRouter().route(.escape, from: .key, to: x.session)
    y.session.perform(intent: .returnToGrid)
    #expect(x.session.mode == .viewing && x.session.previewSet != nil)
    #expect(x.session.inspectorFocus.focus == .canvas && x.host.returns == 0)
    #expect(y.session.mode == .browsing && y.session.previewSet == nil)
    #expect(y.session.selection.currentItemID == y.items[1] && y.host.returns == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func i444DisabledIntentsAreNoOpsAndReturnIsIdempotent() {
    let returnable = Intent444Fixture(.preview)
    returnable.session.perform(intent: .returnToGrid)
    let once = returnable.session.browsingState
    returnable.session.perform(intent: .returnToGrid)
    let twice = returnable.session.browsingState
    #expect(once.mode == twice.mode && once.selection == twice.selection && once.previewSet == twice.previewSet)
    #expect(once.scrollAnchor == twice.scrollAnchor && once.items == twice.items && once.sourceVersion == twice.sourceVersion)
    #expect(returnable.host.returns == 1)
    for source in [Intent444Source.browsing, .files, .single] {
        let f = Intent444Fixture(source)
        let before = f.session.browsingState, prefs = f.store.value
        f.session.perform(intent: .returnToGrid)
        f.session.perform(intent: .toggleSidebar)
        let after = f.session.browsingState
        #expect(before.mode == after.mode && before.selection == after.selection && before.previewSet == after.previewSet, "\(source)")
        #expect(f.host.returns == 0 && f.host.folderReturns == 0 && f.host.intents.isEmpty, "\(source)")
        #expect(f.store.value == prefs, "\(source)")
    }
    // A preview whose host has no sidebar does not toggle either.
    let unavailable = Intent444Fixture(.preview, available: false)
    unavailable.session.perform(intent: .toggleSidebar)
    #expect(unavailable.host.intents.isEmpty && unavailable.store.value.gridSidebarVisible)
}

@Test(.timeLimit(.minutes(2)), arguments: Intent444Source.allCases, [false, true])
@MainActor func i444CanToggleViewerSidebarTruthTable(source: Intent444Source, visible: Bool) {
    for available in [false, true] {
        let f = Intent444Fixture(source, available: available)
        f.store.value.gridSidebarVisible = visible
        let oracle = source == .preview && available
        #expect(f.session.canToggleViewerSidebar == oracle, "\(source) available \(available)")
        // Owner decision 2026-11-04: the viewer's sidebar is its own state and starts hidden, whatever the grid shows.
        #expect(!f.session.isViewerSidebarShown, "\(source) available \(available) grid visible \(visible)")
        f.session.perform(intent: .toggleSidebar)
        #expect(f.session.isViewerSidebarShown == oracle, "\(source) available \(available) grid visible \(visible)")
        #expect(f.store.value.gridSidebarVisible == visible, "the grid's visibility is untouched")
    }
    let legacy = LegacyChromeHost()
    let session = ViewerSession(host: legacy)
    session.chromeHost = legacy
    let items = [ItemID.ephemeral(UUID()), .ephemeral(UUID())]
    session.beginBrowsing(items: items, sourceVersion: .init(1), scrollAnchor: nil)
    session.select(items[0])
    CommandRouter().route(.preview, from: .key, to: session)
    #expect(legacy.viewerSidebarAvailable == false)
    #expect(session.canToggleViewerSidebar == false && session.isViewerSidebarShown == false)
    // A host written before #444 keeps the default effect: an intent changes nothing.
    for intent in [ViewerChromeIntent.toggleSidebar, .returnToGrid] { legacy.performChromeIntent(intent) }
    #expect(session.mode == .viewing && session.previewSet != nil && session.displayPreferences.gridSidebarVisible)
    let detached = Intent444Fixture(.preview, available: true)
    detached.session.chromeHost = nil
    #expect(detached.session.canToggleViewerSidebar == false)
}

@Test(.timeLimit(.minutes(2))) @MainActor func i444ToggleSidebarIntentReachesHostOnlyWhenEnabled() {
    let off = Intent444Fixture(.preview, available: false)
    off.session.perform(intent: .toggleSidebar)
    #expect(off.host.intents.isEmpty && off.store.value.gridSidebarVisible && !off.session.isViewerSidebarShown)
    let on = Intent444Fixture(.preview, available: true)
    let prefs = on.store.value
    #expect(!on.session.isViewerSidebarShown)
    on.session.perform(intent: .toggleSidebar)
    #expect(on.host.intents == [.toggleSidebar])
    #expect(on.session.isViewerSidebarShown && on.session.viewerSidebarVisible)
    on.session.perform(intent: .toggleSidebar)
    #expect(on.host.intents == [.toggleSidebar, .toggleSidebar])
    #expect(!on.session.isViewerSidebarShown && !on.session.viewerSidebarVisible)
    #expect(on.store.value == prefs, "toggling in the viewer never writes the grid's preferences")
}

/// Owner decision 2026-11-04 (#444): 进入大图时侧栏默认隐藏；在大图里点「显示侧栏」后，在这次查看中保持，返回网格时网格侧栏照旧。
/// "This viewing" is one folder preview: it lasts across ←/→ and ends when the preview ends (返回网格, Esc, or the
/// folder being replaced); the next entry starts hidden again.
@Test(.timeLimit(.minutes(2)), arguments: [true, false])
@MainActor func i444ViewerSidebarIsIndependentAndStartsHiddenEachViewing(gridVisible: Bool) {
    let f = Intent444Fixture(.browsing, available: true)
    f.store.value.gridSidebarVisible = gridVisible
    let prefs = f.store.value
    func enter() { f.session.select(f.items[1]); CommandRouter().route(.preview, from: .key, to: f.session) }
    enter()
    #expect(f.session.mode == .viewing && !f.session.isViewerSidebarShown, "entry starts hidden")
    f.session.perform(intent: .toggleSidebar)
    #expect(f.session.isViewerSidebarShown)
    CommandRouter().route(.next, from: .key, to: f.session)
    #expect(f.session.isViewerSidebarShown, "the choice holds across ←/→ in this viewing")
    f.session.perform(intent: .returnToGrid)
    #expect(f.session.mode == .browsing && !f.session.viewerSidebarVisible)
    #expect(f.store.value == prefs, "the grid's sidebar is exactly as it was")
    enter()
    #expect(!f.session.isViewerSidebarShown, "the second entry starts hidden again")
    f.session.perform(intent: .toggleSidebar)
    CommandRouter().route(.escape, from: .key, to: f.session)
    #expect(f.session.mode == .browsing)
    enter()
    #expect(!f.session.isViewerSidebarShown, "Esc's return ends the viewing too")
    f.session.perform(intent: .toggleSidebar)
    f.session.beginBrowsing(items: f.items.reversed(), sourceVersion: .init(2), scrollAnchor: nil)
    #expect(!f.session.viewerSidebarVisible, "another folder replacing the preview ends the viewing")
    #expect(f.store.value == prefs)
}
