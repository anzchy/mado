import Observation
import MadoCore

/// Native effects only; command policy and window state belong to the Session.
@MainActor public protocol ViewerSessionHost: AnyObject {
    var hasImage: Bool { get }
    func performCanvas(_ command: CommandID, from entry: CommandEntry)
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double?
    func requestOpen()
    func applyFocus(_ focus: FocusContext)
    func showInspector(_ visible: Bool)
    func presentGridItem(_ id: ItemID)
    func returnToGrid()
}

public enum ViewerMode: Sendable { case browsing, viewing }

/// One state owner per window. It never creates a native window.
@MainActor @Observable public final class ViewerSession: DisplayPreferencesObserver {
    public let imageLoader: ViewerImageLoader
    private let preferencesStore: any DisplayPreferencesStore
    private let clock: any ViewerClock
    public weak var host: (any ViewerSessionHost)?
    public private(set) var zoomMode: ViewerZoomMode = .fit
    public func beginCanvasImage() { zoomMode = .fit }
    public func reportCanvasZoom(_ value: Double) { zoomMode = .custom(value) }
    public var searchTerm = ""
    public private(set) var displayPreferences: DisplayPreferences
    public private(set) var selection = BrowserSelection()
    public private(set) var previewSet: PreviewSet? {
        didSet {
            if oldValue != nil && previewSet == nil { applyPreferredFolderSort() }
            // #444: a folder preview starting or ending starts or ends one viewing; its sidebar starts hidden.
            if (oldValue == nil) != (previewSet == nil) { viewerSidebarVisible = false }
        }
    }
    /// While a viewed set is open, its reconciler owns deletion successors.
    public var allowsFolderScanPresentation: Bool { previewSet == nil && filePreviewSet == nil }
    public internal(set) var filePreviewSet: FilePreviewSet? {
        didSet { if oldValue != nil && filePreviewSet == nil { applyPreferredFolderSort() } }
    }
    public var folderScan: FolderScanCoordinator? { didSet { applyPreferredFolderSort() } }
    let inputNavigationIntent = AccessIntent()
    public private(set) var mode: ViewerMode = .viewing
    public private(set) var scrollAnchor: ItemID?
    public private(set) var inspectorFocus = InspectorFocus()
    public private(set) var chrome: ViewerChromeState
    public private(set) var isMenuTracking = false
    private var orderedItemIDs: [ItemID] = []
    var folderEntryRestore: FolderEntryRestorePoint?
    private var sourceVersion = PreviewSourceVersion(0)
    public var currentItemID: ItemID? {
        mode == .viewing ? previewSet?.currentItemID : selection.currentItemID
    }
    public weak var chromeHost: (any ViewerChromeHost)? { didSet { synchronizeChrome() } }
    public func setChromeInteraction(_ reason: ChromeLockReason, active: Bool) {
        chrome.setLock(reason, active: active, at: clock.now)
        synchronizeChrome()
    }
    private var pointerAtTop = false
    public var trafficLightsVisible: Bool { !chrome.isHidden || pointerAtTop }
    public func pointerMoved(in region: ChromePointerRegion) {
        pointerAtTop = region == .top
        if region == .bottom || (!chrome.isHidden && region != .outside) { activity() }
        else { synchronizeChrome() }
    }
    private var chromeScheduler: (any ViewerChromeScheduling)?
    private var scheduledChromeDeadline: Double?
    private var chromeWakeupConsumed = false
    public func installChromeScheduler(_ scheduler: any ViewerChromeScheduling) {
        chromeScheduler = scheduler
        chromeWakeupConsumed = true
        synchronizeChrome()
    }
    private func synchronizeChrome() {
        chromeHost?.applyChrome(toolsVisible: !chrome.isHidden, trafficLightsVisible: trafficLightsVisible)
        guard let chromeScheduler else { return }
        let deadline = nextHideDeadline
        guard chromeWakeupConsumed || deadline != scheduledChromeDeadline else { return }
        chromeWakeupConsumed = false
        scheduledChromeDeadline = deadline
        chromeScheduler.replace(deadline: deadline) { [weak self] in
            self?.chromeWakeupConsumed = true
            self?.advanceChrome()
        }
    }
    public var nextHideDeadline: Double? { chrome.nextHideDeadline }
    public init(preferencesStore: any DisplayPreferencesStore = InMemoryDisplayPreferencesStore(),
                clock: any ViewerClock = MonotonicViewerClock(), hideDelay: Double = 2.5,
                host: (any ViewerSessionHost)? = nil, imageLoader: ViewerImageLoader = ViewerImageLoader()) {
        self.imageLoader = imageLoader
        self.preferencesStore = preferencesStore
        self.displayPreferences = preferencesStore.value
        self.clock = clock
        self.host = host
        chrome = ViewerChromeState(now: clock.now, hideDelay: hideDelay)
        preferencesDidChange(preferencesStore.value)
        preferencesStore.observe(self)
    }
    public func beginBrowsing(items: [ItemID], sourceVersion: PreviewSourceVersion, scrollAnchor: ItemID?) {
        mode = .browsing
        previewSet = nil
        self.scrollAnchor = scrollAnchor
        updateItems(items, sourceVersion: sourceVersion)
    }
    struct BrowsingState {
        let mode: ViewerMode, selection: BrowserSelection, previewSet: PreviewSet?, scrollAnchor: ItemID?
        let items: [ItemID], sourceVersion: PreviewSourceVersion
    }
    var browsingState: BrowsingState {
        BrowsingState(mode: mode, selection: selection, previewSet: previewSet, scrollAnchor: scrollAnchor,
            items: orderedItemIDs, sourceVersion: sourceVersion)
    }
    func restoreBrowsingState(_ state: BrowsingState) {
        mode = state.mode
        selection = state.selection
        previewSet = state.previewSet
        scrollAnchor = state.scrollAnchor
        orderedItemIDs = state.items
        sourceVersion = state.sourceVersion
    }
    public func leaveBrowsing() {
        mode = .viewing
        previewSet = nil
        selection = BrowserSelection()
        scrollAnchor = nil
        orderedItemIDs = []
    }
    /// Caller reports the navigable IDs, so deleted and filtered-out items are both absent. While browsing, an absent
    /// Current Item moves to its nearest survivor, as it does for a deletion.
    public func updateItems(_ items: [ItemID], sourceVersion: PreviewSourceVersion) {
        let old = orderedItemIDs, alive = Set(items), gone = selection.currentItemID
        orderedItemIDs = items
        self.sourceVersion = sourceVersion
        selection.reconcile(with: items)
        // Browsing: a removed Current Item moves to the nearest survivor in the old order, successor first.
        if mode == .browsing, previewSet == nil, selection.currentItemID == nil,
           let gone, let index = old.firstIndex(of: gone),
           let next = old[(index + 1)...].first(where: alive.contains) ?? old[..<index].last(where: alive.contains) {
            selection.focus(next, in: items)
        }
        let previous = previewSet?.currentItemID
        previewSet?.reconcile(availableItemIDs: items)
        if previous != previewSet?.currentItemID, previous != nil {
            if let current = previewSet?.currentItemID {
                host?.presentGridItem(current)
            } else {
                if let origin = previewSet?.origin {
                    selection = origin.selection
                    scrollAnchor = origin.scrollAnchor
                }
                previewSet = nil
                mode = .browsing
                host?.returnToGrid()
            }
        }
        if let scrollAnchor, !items.contains(scrollAnchor) { self.scrollAnchor = nil }
    }
    public func select(_ id: ItemID, modifier: SelectionModifier = .plain) {
        selection.click(id, modifier: modifier, in: orderedItemIDs)
    }
    public func clearSelection() { selection.clearSelection() }
    public func focus(_ id: ItemID) { selection.focus(id, in: orderedItemIDs) }
    public func contextMenuTarget(for id: ItemID) -> ContextMenuTarget {
        ContextMenuTarget(clickedItemID: id, selection: selection, items: orderedItemIDs)
    }
    public func resolve(_ target: ContextMenuTarget) -> [ItemID] {
        target.resolve(availableItemIDs: orderedItemIDs)
    }
    public func preview(_ menu: ImageContextMenu) {
        guard mode == .browsing else { return }
        let live = Set(orderedItemIDs)
        let isSelection = menu.target.itemIDs.count > 1
        let items = (isSelection ? menu.target.itemIDs : menu.openingItemIDs).filter(live.contains)
        guard items.contains(menu.clickedItemID) || (isSelection && !items.isEmpty) else { return }
        let start = isSelection ? menu.openingSelection.currentItemID : menu.clickedItemID
        previewSet = PreviewSet(items: items, sourceVersion: sourceVersion,
            origin: PreviewOrigin(selection: menu.openingSelection, scrollAnchor: scrollAnchor),
            startingAt: start, selectionPreview: isSelection)
        mode = .viewing
        updateFocus(.canvas)
        host?.applyFocus(.canvas)
        if let id = previewSet?.currentItemID { host?.presentGridItem(id) }
    }
    private var appMenuTracking = false
    private var chromeMenuOpen = false
    private var imageContextMenuOpen = false
    public func setMenuTracking(_ tracking: Bool) {
        appMenuTracking = tracking
        applyMenuLock()
    }
    /// #444: a viewer pod menu (缩放模式, 更多) is open. It holds the menu lock on its own, so the App menu
    /// closing (or a command routed from the pod menu) cannot release the lock while the pod menu is on screen.
    public func setChromeMenuOpen(_ open: Bool) {
        chromeMenuOpen = open
        applyMenuLock()
    }
    public func setImageContextMenuOpen(_ open: Bool) {
        imageContextMenuOpen = open
        applyMenuLock()
    }
    private func applyMenuLock() {
        isMenuTracking = appMenuTracking || chromeMenuOpen || imageContextMenuOpen
        chrome.setLock(.menu, active: isMenuTracking, at: clock.now)
        synchronizeChrome()
    }
    public func updateFocus(_ context: FocusContext) {
        inspectorFocus.updateFocus(context)
        syncFocusLock()
    }
    public func setInspectorVisible(_ visible: Bool) {
        inspectorFocus.setVisible(visible)
        chrome.setLock(.inspector, active: visible, at: clock.now)
        syncFocusLock()
        host?.showInspector(visible)
        host?.applyFocus(inspectorFocus.focus)
    }
    public func tab(reverse: Bool) {
        activity()
        if let chromeHost {
            let focus = inspectorFocus.focus
            if reverse && focus == .canvas && inspectorFocus.isVisible {
                inspectorFocus.updateFocus(.textInput)
            } else if focus == .canvas || focus == .tools || reverse {
                if chromeHost.focusChromeTool(reverse: reverse, entering: focus != .tools) {
                    inspectorFocus.updateFocus(.tools)
                } else {
                    inspectorFocus.updateFocus(focus == .tools && !reverse && inspectorFocus.isVisible ? .textInput : .canvas)
                }
            } else { inspectorFocus.escape() }
        } else { inspectorFocus.tab(reverse: reverse) }
        syncFocusLock()
        host?.applyFocus(inspectorFocus.focus)
    }
    private func syncFocusLock() {
        chrome.setLock(.keyboardFocus, active: inspectorFocus.focus != .canvas, at: clock.now)
        synchronizeChrome()
    }
    public func preferencesDidChange(_ preferences: DisplayPreferences) {
        displayPreferences = preferences
        chrome.setPinned(preferences.alwaysShowTools, at: clock.now)
        // Unchanged true values must not count as a new Filmstrip interaction.
        if chrome.locks.contains(.filmstrip) != preferences.filmstripExpanded {
            chrome.setLock(.filmstrip, active: preferences.filmstripExpanded, at: clock.now)
        }
        synchronizeChrome()
        applyPreferredFolderSort()
    }
    public func setFolderLoopEnabled(_ enabled: Bool) {
        guard preferencesStore.value.loopThroughImages != enabled else { return }
        var preferences = preferencesStore.value
        preferences.loopThroughImages = enabled
        preferencesStore.value = preferences
    }
    private func applyPreferredFolderSort() {
        guard previewSet == nil, filePreviewSet == nil, let folderScan else { return }
        let preferences = preferencesStore.value
        var conditions = folderScan.conditions
        guard conditions.sort != preferences.folderSort || conditions.direction != preferences.folderSortDirection else { return }
        conditions.sort = preferences.folderSort
        conditions.direction = preferences.folderSortDirection
        folderScan.setConditions(conditions)
    }
    func saveFolderSort(_ conditions: FolderViewConditions) {
        guard preferencesStore.value.folderSort != conditions.sort ||
            preferencesStore.value.folderSortDirection != conditions.direction else { return }
        var preferences = preferencesStore.value
        preferences.folderSort = conditions.sort
        preferences.folderSortDirection = conditions.direction
        preferencesStore.value = preferences
    }
    public func activity() { chrome.activity(at: clock.now); synchronizeChrome() }
    public func advanceChrome() { chrome.advance(to: clock.now); synchronizeChrome() }
    /// The binding modifier matters in Grid: the same zoom IDs also have bare viewer alternates.
    public func isEnabled(_ command: CommandID, commandModified: Bool = false) -> Bool {
        if mode == .browsing, command.commandKey != nil {
            return commandModified && command != .fit && inspectorFocus.focus != .textInput
        }
        return switch command {
        case .fit, .actualPixels, .zoomIn, .zoomOut: imageCommandsAvailable
        case .escape: inspectorFocus.focus != .canvas || canReturnToSource
        case .open: true
        case .inspector: inspectorFocus.isVisible || imageCommandsAvailable || (mode == .browsing && currentItemID != nil)
        case .preview, .enter: mode == .browsing && !orderedItemIDs.isEmpty
        case .previous, .next:
            if let filePreviewSet { filePreviewSet.canMove(forward: command == .next, mayWrap: displayPreferences.loopThroughImages) }
            else {
                if mode == .viewing, previewSet == nil, folderScan?.isReadingFolder == true { false }
                else if mode == .viewing, previewSet == nil,
                        let enabled = folderScan?.canMove(command == .next ? .next : .previous, currentURL: imageLoader.fileURL,
                                                         mayWrap: displayPreferences.loopThroughImages) { enabled }
                else {
                    mode == .viewing && (host?.hasImage == true || imageStatus != .empty)
                        && (previewSet != nil || (host as? any ViewerSessionNavigationHost)?.canNavigate == true)
                }
            }
        case .search: false
        }
    }
    /// #444: Esc (with canvas focus) and 返回网格 return to the grid of a folder preview, or a single image to its folder.
    public var canReturnToSource: Bool { (filePreviewSet == nil && previewSet?.origin != nil) || canReturnSingleImage }
    /// The return part of Esc, without its keyboard-focus step: 返回网格 returns even when a tool holds focus.
    public func returnToSource() {
        if filePreviewSet == nil, let origin = previewSet?.origin {
            selection = origin.selection
            scrollAnchor = origin.scrollAnchor
            previewSet = nil
            mode = .browsing
            host?.returnToGrid()
        } else if canReturnSingleImage {
            (host as? any ViewerSingleImageReturnHost)?.returnSingleImageToFolder()
        }
    }
    /// #444: the folder sidebar beside the viewer exists only for a preview entered from a folder grid.
    public var canToggleViewerSidebar: Bool {
        mode == .viewing && filePreviewSet == nil && previewSet?.origin != nil && chromeHost?.viewerSidebarAvailable == true
    }
    /// Owner decision 2026-11-04: the viewer's sidebar is independent of the grid's and starts hidden on every
    /// viewing; 显示侧栏 and ⌃⌘S keep it for this viewing (one folder preview, across ←/→).
    public private(set) var viewerSidebarVisible = false
    public var isViewerSidebarShown: Bool { canToggleViewerSidebar && viewerSidebarVisible }
    public func perform(intent: ViewerChromeIntent) {
        switch intent {
        case .returnToGrid:
            guard canReturnToSource else { return }
            activity()
            if inspectorFocus.focus != .canvas {
                inspectorFocus.escape()
                syncFocusLock()
                host?.applyFocus(.canvas)
            }
            returnToSource()
        case .toggleSidebar:
            guard canToggleViewerSidebar else { return }
            activity()
            viewerSidebarVisible.toggle()
            chromeHost?.performChromeIntent(.toggleSidebar)
        }
    }
    private var canReturnSingleImage: Bool {
        mode == .viewing && previewSet == nil && filePreviewSet == nil
            && (host as? any ViewerSingleImageReturnHost)?.canReturnToFolder == true
    }
    func perform(_ command: CommandID, from entry: CommandEntry) {
        activity()
        if mode == .browsing, command == .zoomIn || command == .zoomOut || command == .actualPixels {
            var preferences = preferencesStore.value
            switch command {
            case .zoomIn: preferences.thumbnailSize += 20
            case .zoomOut: preferences.thumbnailSize -= 20
            default: preferences.thumbnailSize = 220
            }
            preferencesStore.value = preferences
        } else if command == .open {
            host?.requestOpen()
        } else if command == .inspector {
            setInspectorVisible(!inspectorFocus.isVisible)
        } else if command == .escape {
            if inspectorFocus.focus != .canvas {
                inspectorFocus.escape()
                syncFocusLock()
                host?.applyFocus(.canvas)
            } else {
                returnToSource()
            }
        } else if command == .preview || command == .enter {
            previewSet = PreviewSet(items: orderedItemIDs, sourceVersion: sourceVersion,
                origin: PreviewOrigin(selection: selection, scrollAnchor: scrollAnchor))
            mode = .viewing
            updateFocus(.canvas)
            host?.applyFocus(.canvas)
            if let id = previewSet?.currentItemID { host?.presentGridItem(id) }
        } else if command == .next || command == .previous {
            inputNavigationIntent.invalidate()
            if filePreviewSet != nil {
                moveInputFile(forward: command == .next)
            } else if previewSet != nil {
                let previous = previewSet?.currentItemID
                previewSet?.move(forward: command == .next, mayWrap: displayPreferences.loopThroughImages)
                if let id = previewSet?.currentItemID, id != previous { host?.presentGridItem(id) }
            } else if mode == .viewing,
                      folderScan?.move(command == .next ? .next : .previous, currentURL: imageLoader.fileURL,
                                       mayWrap: displayPreferences.loopThroughImages) == true {
            } else {
                (host as? any ViewerSessionNavigationHost)?.navigate(command == .next ? .next : .previous)
            }
        } else {
            if command == .fit { zoomMode = .fit }
            if command == .actualPixels { zoomMode = .actualPixels }
            let finalZoom = host?.performCanvasZoom(command, from: entry)
            if (command == .zoomIn || command == .zoomOut), let finalZoom {
                reportCanvasZoom(finalZoom)
            }
        }
    }
}
