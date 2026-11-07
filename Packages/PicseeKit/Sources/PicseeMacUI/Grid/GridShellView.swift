import AppKit
import PicseeApplication
import PicseeCore

@MainActor private final class GridSidebarToggleButton: NSButton {
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}

@MainActor private final class GridSidebarDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onFinish: (() -> Void)?
    var onAdjust: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX)
    }
    override func mouseUp(with event: NSEvent) { onFinish?() }
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onAdjust?(-8)
        case 124: onAdjust?(8)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { onAdjust?(8); return true }
    override func accessibilityPerformDecrement() -> Bool { onAdjust?(-8); return true }
}

/// Page 11/12/24/29 frame shared by the grid and folder-reading state.
@MainActor public final class GridShellView: NSView, NSSearchFieldDelegate, DisplayPreferencesObserver {
    public let mainContent = NSView()
    public let sidebar = NSView()
    public let footer = NSView()
    public let toggleButton: NSButton = GridSidebarToggleButton()
    public let searchField = NSSearchField()
    public let searchButton: NSButton = GridSidebarToggleButton()
    public var emptyStateTitle: NSTextField? { emptyTitle }
    public var emptyStateDetail: NSTextField? { emptyDetail }
    public let sortButton: NSButton = GridSidebarToggleButton()
    public let favoritesButton: NSButton = GridSidebarToggleButton()
    public let recentsButton: NSButton = GridSidebarToggleButton()
    public let infoButton: NSButton = GridSidebarToggleButton()
    public let displayButton: NSButton = GridSidebarToggleButton()
    public let searchStatus = NSTextField(labelWithString: "")
    public var onSearchChange: ((String) -> Void)?
    public var onClearSearch: (() -> Void)?
    public var onSort: ((FolderMenuAction) -> Void)?
    public var onSelectFolder: ((URL) -> Void)?
    public var onOpenSortMenu: ((NSButton, NSMenu) -> Void)?
    public var sortConditions: (() -> FolderViewConditions)?
    public var onMainFrameChange: ((NSRect) -> Void)?
    /// Runs after every layout pass resets the main-content views, including the Grid's Bottom Bar extension;
    /// owners that carve the main area (the rebind strip) re-place their views here.
    public var onMainContentLayout: (() -> Void)?
    public var onOpenRecent: ((RecentFolder) -> Void)?
    public var onDropFolders: (([URL]) -> Void)?
    public weak var session: ViewerSession?
    public let emptyFolderView = EmptyFolderStateView()
    public var emptyFolderVisible: Bool { !isHidden && !emptyFolderView.isHidden }
    private var emptyFolderRequest: (recents: [RecentFolder], now: Date)?
    private var footerActionsRequested = true
    private var searchEmptyRequested = false
    private let preferencesStore: any DisplayPreferencesStore
    var reduceTransparencyOverride: Bool? { didSet { refreshAppearance() } }
    private let divider = GridSidebarDivider()
    private let folderName = NSTextField(labelWithString: "")
    public let folderTree = GridSidebarTreeView(frame: .zero)
    private let sidebarRule = NSView()
    private let footerLeadingDivider = NSView()
    private let currentFileStatus = NSTextField(labelWithString: "")
    private var currentFileName = ""
    private var countText = ""
    private var countIsSearchSummary = false
    private var isReading = false
    /// 「读取失败」 (24F-A, #238): the footer reads `–` / Read incomplete and the read folder's row `—`.
    private var isReadFailed = false
    /// Reading or failed: the footer shows the read's status, not the stored name and count.
    private var showsReadStatus: Bool { isReading || isReadFailed }
    /// Page 26 (#332): the tree's current folder lost access, whatever the cause; the footer reads `–` / Unavailable.
    private var showsLostAccess: Bool { !folderTree.isHidden && folderTree.currentAccessLossCause != nil }
    /// The count slot shows a status, not the stored count, so it never truncates as a search summary.
    private var showsCountStatus: Bool { showsReadStatus || showsLostAccess || !emptyFolderView.isHidden }
    private let keyboardHint = NSView()
    private let spaceKeycap = NSTextField(labelWithString: "Space")
    private let quickLookLabel = NSTextField(labelWithString: "")
    private let emptyState = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: String(localized: "No matching images"))
    private let emptyDetail = NSTextField(labelWithString: String(localized: "Try another filename or clear the search."))
    public let clearSearchButton: NSButton = GridSidebarToggleButton()
    private var lastMainFrame: NSRect?
    private var dragStartWidth: CGFloat?
    private var liveSidebarWidth: CGFloat?
    private weak var focusAnchor: NSView?
    private weak var focusTail: NSView?
    private var footerActionsEnabled = true
    private var preserveRestoredSearchEditor = false
    private var comingSoonEntries: [ObjectIdentifier: EntryPoint] = [:]
    /// Page 15 (#114): the footer Display button's popover, a shell subview above the main content and page 22.
    public let displayPanel: GridDisplayPanelView
    public var isDisplayPanelOpen: Bool { displayPanel.superview === self }
    /// The display options last sent to the grids; the store is their one source, so an attached grid takes them.
    private var gridDisplayOptions: GridDisplayOptions
    private let optionedGrids = NSHashTable<GridBrowserView>.weakObjects()

    public init(frame: NSRect, preferencesStore: any DisplayPreferencesStore) {
        self.preferencesStore = preferencesStore
        displayPanel = GridDisplayPanelView(preferencesStore: preferencesStore)
        gridDisplayOptions = GridDisplayOptions(preferencesStore.value)
        super.init(frame: frame)
        addSubview(sidebar)
        addSubview(mainContent)
        addSubview(footer)
        footer.addSubview(toggleButton)
        footer.addSubview(searchField)
        footer.addSubview(searchButton)
        footer.addSubview(searchStatus)
        footer.addSubview(sortButton)
        footer.addSubview(infoButton)
        footer.addSubview(displayButton)
        footer.addSubview(footerLeadingDivider)
        footer.addSubview(currentFileStatus)
        footer.addSubview(keyboardHint)
        keyboardHint.addSubview(spaceKeycap)
        keyboardHint.addSubview(quickLookLabel)
        sidebar.addSubview(favoritesButton)
        sidebar.addSubview(recentsButton)
        mainContent.addSubview(emptyState)
        mainContent.addSubview(emptyFolderView)
        emptyFolderView.contentInsets = NSEdgeInsets(top: 16, left: 0, bottom: 30, right: 0)
        emptyFolderView.isHidden = true
        emptyFolderView.onSelectSubfolder = { [weak self] in self?.onSelectFolder?($0) }
        emptyFolderView.onOpenRecent = { [weak self] in self?.onOpenRecent?($0) }
        emptyFolderView.onDropFolders = { [weak self] in self?.onDropFolders?($0) }
        emptyFolderView.onIncludeSubfolders = { [weak self] in self?.session?.setFolderRecursiveEnabled(true) }
        emptyFolderView.onChooseFolder = { [weak self] in
            if let session = self?.session { CommandRouter().route(.open, from: .button, to: session) }
        }
        emptyState.addSubview(emptyTitle)
        emptyState.addSubview(emptyIcon)
        emptyState.addSubview(emptyDetail)
        emptyState.addSubview(clearSearchButton)
        emptyState.isHidden = true
        emptyState.setAccessibilityIdentifier("grid.search.empty")
        emptyTitle.font = .systemFont(ofSize: 16, weight: .medium)
        emptyTitle.textColor = DesignColor.textPrimary.nsColor
        emptyIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyDetail.textColor = DesignColor.textSecondary.nsColor
        emptyDetail.font = .systemFont(ofSize: 13)
        setEmptyDetailText(emptyDetail.stringValue)
        emptyDetail.lineBreakMode = .byTruncatingMiddle
        emptyTitle.alignment = .center
        emptyDetail.alignment = .center
        clearSearchButton.title = String(localized: "Clear Search")
        clearSearchButton.bezelStyle = .rounded
        clearSearchButton.isBordered = true
        clearSearchButton.bezelColor = DesignColor.primaryFill.nsColor
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearFromButton)
        clearSearchButton.setAccessibilityIdentifier("grid.search.clear")
        searchField.placeholderString = String(localized: "Search current folder")
        searchField.setAccessibilityLabel(String(localized: "Search current folder"))
        searchField.setAccessibilityIdentifier("grid.search.field")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.isHidden = true
        searchButton.isBordered = false
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchButton.target = self
        searchButton.action = #selector(openSearchFromButton)
        searchButton.setAccessibilityLabel(String(localized: "Search images"))
        searchButton.setAccessibilityIdentifier("grid.search.button")
        searchStatus.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        searchStatus.textColor = DesignColor.textSecondary.nsColor
        searchStatus.lineBreakMode = .byTruncatingTail
        searchStatus.isHidden = true
        searchStatus.setAccessibilityIdentifier("grid.folder-count")
        currentFileStatus.font = .systemFont(ofSize: 12)
        currentFileStatus.textColor = DesignColor.textSecondary.nsColor
        currentFileStatus.lineBreakMode = .byTruncatingTail
        currentFileStatus.maximumNumberOfLines = 1
        currentFileStatus.isHidden = true
        currentFileStatus.setAccessibilityIdentifier("grid.current-file-status")
        footerLeadingDivider.setAccessibilityIdentifier("grid.footer.leading-divider")
        footerLeadingDivider.wantsLayer = true
        keyboardHint.setAccessibilityIdentifier("grid.keyboard-hint")
        spaceKeycap.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        spaceKeycap.textColor = DesignColor.textSecondary.nsColor
        spaceKeycap.alignment = .center
        spaceKeycap.wantsLayer = true
        spaceKeycap.layer?.cornerRadius = DesignMetrics.radii["inner"]!
        spaceKeycap.layer?.borderWidth = 1
        quickLookLabel.stringValue = String(localized: "Quick Look")
        quickLookLabel.font = .systemFont(ofSize: 12)
        quickLookLabel.textColor = DesignColor.textPrimary.nsColor
        sortButton.isBordered = false
        sortButton.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        sortButton.target = self
        sortButton.action = #selector(showSortMenu)
        sortButton.toolTip = String(localized: "Sort images")
        sortButton.setAccessibilityLabel(String(localized: "Sort images"))
        sortButton.setAccessibilityIdentifier("grid.sort.button")
        configureComingSoon(favoritesButton, entry: .favorites, title: String(localized: "Personal Favorites"), identifier: "grid.favorites.row", systemImage: "heart")
        configureComingSoon(recentsButton, entry: .recents, title: String(localized: "Recently Viewed"), identifier: "grid.recents.row", systemImage: "clock")
        configureComingSoon(infoButton, entry: .footerInfo, title: String(localized: "Show Image Information"), identifier: "grid.info.button", systemImage: "info.circle", iconOnly: true)
        configureDisplayButton()
        displayPanel.onClose = { [weak self] in self?.setDisplayPanelOpen(false) }
        favoritesButton.alignment = .left
        recentsButton.alignment = .left
        sidebar.addSubview(folderName)
        sidebar.addSubview(folderTree)
        sidebar.addSubview(sidebarRule)
        sidebar.addSubview(divider)
        sidebarRule.setAccessibilityIdentifier("grid.sidebar.divider")
        sidebarRule.wantsLayer = true
        sidebar.setAccessibilityIdentifier("grid.sidebar")
        footer.setAccessibilityIdentifier("grid.footer")
        mainContent.setAccessibilityIdentifier("grid.main")
        divider.setAccessibilityIdentifier("grid.sidebar.resize")
        divider.setAccessibilityElement(true)
        divider.setAccessibilityRole(.splitter)
        divider.setAccessibilityLabel(String(localized: "Resize sidebar"))
        divider.setAccessibilityMinValue(NSNumber(value: 160))
        divider.setAccessibilityMaxValue(NSNumber(value: 320))
        divider.onDrag = { [weak self] totalOffset in
            guard let self else { return }
            let start = dragStartWidth ?? CGFloat(preferencesStore.value.gridSidebarWidth)
            dragStartWidth = start
            setLiveSidebarWidth(start + totalOffset)
        }
        divider.onFinish = { [weak self] in self?.finishSidebarDrag() }
        divider.onAdjust = { [weak self] delta in
            guard let self else { return }
            resizeSidebar(to: CGFloat(preferencesStore.value.gridSidebarWidth) + delta)
        }
        folderName.lineBreakMode = .byTruncatingTail
        folderName.maximumNumberOfLines = 1
        folderName.isHidden = true
        folderName.font = .systemFont(ofSize: 12, weight: .medium)
        folderName.setAccessibilityIdentifier("grid.sidebar.folder")
        folderTree.isHidden = true
        folderTree.onSelectFolder = { [weak self] url in self?.onSelectFolder?(url) }
        toggleButton.bezelStyle = .texturedRounded
        toggleButton.isBordered = false
        toggleButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        toggleButton.target = self
        toggleButton.action = #selector(toggleFromButton)
        toggleButton.setAccessibilityIdentifier("grid.sidebar.toggle")
        toggleButton.wantsLayer = true
        toggleButton.layer?.cornerRadius = DesignMetrics.radii["control"]!
        wantsLayer = true
        sidebar.wantsLayer = true
        footer.wantsLayer = true
        refreshAppearance()
        refreshToggleLabel()
        preferencesStore.observe(self)
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(accessibilityOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        needsLayout = true
    }
    public required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
    @objc private func accessibilityOptionsChanged(_ notification: Notification) { refreshAppearance() }
    private var reduceTransparency: Bool {
        reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            sidebar.layer?.backgroundColor = DesignColor.sidebarBackground.nsColor.cgColor
            sidebarRule.layer?.backgroundColor = DesignColor.divider.nsColor.cgColor
            footer.layer?.backgroundColor = DesignColor.canvasBackground.nsColor
                .withAlphaComponent(reduceTransparency ? 1 : 0.8).cgColor
            footerLeadingDivider.layer?.backgroundColor = DesignColor.divider.nsColor.cgColor
            toggleButton.layer?.backgroundColor = preferencesStore.value.gridSidebarVisible
                ? DesignColor.hoverBackground.nsColor.cgColor : NSColor.clear.cgColor
            toggleButton.contentTintColor = preferencesStore.value.gridSidebarVisible
                ? DesignColor.textPrimary.nsColor : DesignColor.textSecondary.nsColor
            displayButton.layer?.backgroundColor = isDisplayPanelOpen
                ? DesignColor.hoverBackground.nsColor.cgColor : NSColor.clear.cgColor
            spaceKeycap.layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
            spaceKeycap.layer?.borderColor = DesignColor.divider.nsColor.cgColor
        }
    }
    public func showFolder(_ name: String?) {
        folderTree.isHidden = true
        folderName.stringValue = name ?? ""
        folderName.isHidden = name == nil
        folderName.setAccessibilityLabel(name ?? "")
        refreshEmptyFolder()
    }
    public func showFolderTree(current: GridSidebarFolder, parent: GridSidebarFolder?, children: [GridSidebarFolder]) {
        folderName.isHidden = true
        folderTree.isHidden = false
        folderTree.show(current: current, parent: parent, children: children)
        refreshEmptyFolder()
        if mode == .viewerSidebar { onViewerSidebarKeyViewsChange?() }
    }
    /// Page 22 after a complete empty scan (ADR-014); its tiles follow the folder tree's current children.
    public func setEmptyFolderState(_ isEmpty: Bool, recents: [RecentFolder], now: Date) {
        emptyFolderRequest = isEmpty ? (recents, now) : nil
        refreshEmptyFolder()
    }
    /// Page 22 replacing the Reading State takes focus from the content it covers (the hidden collection view).
    private func focusAppearingEmptyFolder() {
        guard let window, !emptyFolderView.isHiddenOrHasHiddenAncestor, let first = emptyFolderView.keyViews.first
        else { return }
        let responder = window.firstResponder
        if responder === window || (responder as? NSView)?.isDescendant(of: mainContent) == true {
            window.makeFirstResponder(first)
        }
    }
    private weak var emptyFolderMirror: ViewerStateHost?
    /// Owner decision C (#137): the viewer's state host shows this same page 22, and its actions route as here.
    public func mirrorEmptyFolderPage(to host: ViewerStateHost) {
        emptyFolderMirror = host
        let mirror = host.emptyFolderView, source = emptyFolderView
        mirror.onSelectSubfolder = { [weak source] in source?.onSelectSubfolder?($0) }
        mirror.onOpenRecent = { [weak source] in source?.onOpenRecent?($0) }
        mirror.onDropFolders = { [weak source] in source?.onDropFolders?($0) }
        mirror.onIncludeSubfolders = { [weak source] in source?.onIncludeSubfolders?() }
        mirror.onChooseFolder = { [weak source] in source?.onChooseFolder?() }
        refreshEmptyFolder()
    }
    private func refreshEmptyFolder() {
        let subfolders = folderTree.isHidden ? [] : folderTree.children.map(\.url)
        let content = emptyFolderRequest.map {
            EmptyFolderContent.make(subfolders: subfolders, recents: $0.recents, now: $0.now,
                                    locale: .current, calendar: .current)
        }
        let appearing = emptyFolderView.isHidden && content != nil
        emptyFolderView.isHidden = content == nil
        var page: EmptyFolderPage?
        if let content {
            var rows: [EmptyFolderRecentRow] = []
            if case .recents(let recents) = content { rows = recents }
            let shown = EmptyFolderPage(subfolders: subfolders, recents: rows,
                                        includeSubfoldersAvailable: session?.folderRecursiveEnabled != true)
            mainContent.addSubview(emptyFolderView, positioned: .above, relativeTo: nil)
            emptyFolderView.frame = emptyFolderFrame
            emptyFolderView.display(subfolders: shown.subfolders, recents: shown.recents,
                                    includeSubfoldersAvailable: shown.includeSubfoldersAvailable)
            page = shown
            if appearing { focusAppearingEmptyFolder() }
        }
        emptyFolderMirror?.setEmptyFolderPage(page)
        if applyStatusText() { needsLayout = true }
        applyFooterState()
    }
    public func updateFolderCount(_ count: Int?, for url: URL) {
        folderTree.updateCount(count, for: url)
    }
    /// #444: `.viewerSidebar` shows only the folder sidebar, beside the viewer canvas; the footer, the grid area
    /// and the display panel belong to the grid surface and hide.
    public enum Mode: Sendable { case grid, viewerSidebar }
    public private(set) var mode: Mode = .grid
    public func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        let viewer = mode == .viewerSidebar
        if viewer { setDisplayPanelOpen(false, restoringFocus: false) }
        // The presentation sizes the viewer's narrowed shell itself; stretching it with the window would lay the tree
        // out once at the window's width first.
        if viewer { autoresizesWidth = autoresizingMask.contains(.width); autoresizingMask.remove(.width) }
        else if autoresizesWidth { autoresizingMask.insert(.width) }
        for part in [footer, mainContent] {
            part.isHidden = viewer
            part.setAccessibilityHidden(viewer)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !viewer { updateKeyViewLoop() }
    }
    /// The widest the viewer's sidebar may be at this window width (the presentation keeps the pods' room).
    /// #444: a new limit lays the sidebar out again even when the shell's frame is unchanged (restoring from the
    /// minimum size gives the shell back the frame it had before).
    public var viewerSidebarLimit = CGFloat.greatestFiniteMagnitude {
        didSet { if viewerSidebarLimit != oldValue { needsLayout = true } }
    }
    private var isRelayingOut = false
    private var autoresizesWidth = false
    /// The grid surface: shown, and not the viewer's sidebar. Grid-only paths (search, footer status) test this.
    public var isGridSurface: Bool { !isHidden && mode == .grid }
    /// Called when the viewer's sidebar replaced its rows; the viewer's key loop links them (ViewerStateFocus).
    public var onViewerSidebarKeyViewsChange: (() -> Void)?
    /// The viewer shows its sidebar by showing or hiding this whole shell (owner decision 2026-11-04: independent of
    /// the grid's preference), so in the viewer the sidebar is always laid out.
    private var sidebarLaidOut: Bool { mode == .viewerSidebar || preferencesStore.value.gridSidebarVisible }
    /// The sidebar's width, a live divider drag included; 0 while it is hidden.
    public var sidebarWidth: CGFloat { mainFrame.minX }
    /// The viewer's sidebar stops in its key loop after the tools: the resize divider, then the folder rows.
    public var viewerSidebarKeyViews: [NSView] {
        guard mode == .viewerSidebar, !isHidden else { return [] }
        return [divider] + folderTree.rows
    }
    public var mainFrame: NSRect {
        let preferred = liveSidebarWidth ?? CGFloat(preferencesStore.value.gridSidebarWidth)
        let sidebarWidth = !sidebarLaidOut ? 0 : mode == .viewerSidebar ? max(0, min(preferred, viewerSidebarLimit)) : preferred
        // In the viewer there is no footer, so the sidebar runs the shell's full height.
        let footerHeight: CGFloat = mode == .viewerSidebar ? 0 : 40
        return NSRect(x: sidebarWidth, y: footerHeight, width: max(0, bounds.width - sidebarWidth),
                      height: max(0, bounds.height - footerHeight))
    }
    public func gridContentFrame(topInset: CGFloat = 0) -> NSRect {
        let bounds = mainContent.bounds
        return NSRect(x: bounds.minX, y: bounds.minY - footer.bounds.height, width: bounds.width,
            height: max(0, bounds.height - topInset + footer.bounds.height))
    }
    /// The page owns the whole recovery-scroll drop target; stack padding is internal.
    private var emptyFolderFrame: NSRect { mainContent.bounds }
    public override func layout() {
        super.layout()
        let main = mainFrame
        sidebar.isHidden = !sidebarLaidOut
        sidebar.frame = NSRect(x: 0, y: main.minY, width: main.minX, height: main.height)
        // The viewer's sidebar mode keeps the hidden grid area (and its collection view) at its last grid size:
        // a zero-width grid would ask AppKit for a zero item size.
        if mode == .grid { mainContent.frame = main }
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 40)
        for content in mainContent.subviews where mode == .grid {
            if let grid = content as? GridBrowserView {
                grid.onThumbnailSizeChange = { [weak self] size in
                    guard let self, self.isGridSurface else { return }
                    var preferences = self.preferencesStore.value
                    preferences.thumbnailSize = size
                    self.preferencesStore.value = preferences
                }
                if !optionedGrids.contains(grid) {
                    optionedGrids.add(grid)
                    grid.displayOptions = gridDisplayOptions
                }
                grid.bottomContentInset = footer.bounds.height
                grid.frame = gridContentFrame()
            } else if content === emptyFolderView {
                content.frame = emptyFolderFrame
            } else {
                content.frame = mainContent.bounds
            }
        }
        let compactFooter = footer.bounds.width < 280
        let toggleWidth: CGFloat = compactFooter ? 16 : 30
        toggleButton.frame = NSRect(x: compactFooter ? 8 : 12, y: compactFooter ? 4 : 5,
                                    width: toggleWidth, height: compactFooter ? 32 : 30)
        footerLeadingDivider.frame = NSRect(x: 52, y: 10, width: 1, height: 20)
        // grid-light.html: 12pt trailing inset, 7pt only through 480pt;
        // toolbar gap 6pt, reduced to 2pt through 800pt.
        let trailingInset: CGFloat = footer.bounds.width <= 480 ? 7 : 12
        let toolGap: CGFloat = footer.bounds.width <= 800 ? 2 : 6
        let buttonWidth: CGFloat = footer.bounds.width <= 480 ? 26 : 30
        displayButton.frame = NSRect(x: footer.bounds.width - trailingInset - buttonWidth, y: 6,
                                     width: buttonWidth, height: 28)
        infoButton.frame = NSRect(x: displayButton.frame.minX - buttonWidth - toolGap, y: 6,
                                  width: buttonWidth, height: 28)
        sortButton.frame = NSRect(x: infoButton.frame.minX - buttonWidth - toolGap, y: 6,
                                  width: buttonWidth, height: 28)
        searchButton.frame = NSRect(x: sortButton.frame.minX - buttonWidth - toolGap, y: 6,
                                    width: buttonWidth, height: 28)
        let statusReserve: CGFloat = 48 + 60 + 8
        let searchWidth = min(190, max(120, sortButton.frame.minX - statusReserve - toolGap))
        searchField.frame = NSRect(x: sortButton.frame.minX - searchWidth - toolGap, y: 6,
                                   width: searchWidth, height: 28)
        keyboardHint.isHidden = !footerActionsEnabled || footer.bounds.width <= 800 || !searchField.isHidden
        keyboardHint.setAccessibilityHidden(keyboardHint.isHidden)
        let keycapWidth = Self.cellWidth(spaceKeycap)
        let quickLookWidth = Self.cellWidth(quickLookLabel)
        let hintWidth = keycapWidth + 5 + quickLookWidth
        // Page 11/12: the hint span's 7pt trailing margin precedes the Bottom Bar's 16pt gap.
        // Match the text box: NSTextField draws 2pt inside its frame, as in the status labels below.
        let hintTextInset: CGFloat = 2
        keyboardHint.frame = NSRect(x: searchButton.frame.minX - 7 - 16 + hintTextInset - hintWidth, y: 6,
                                    width: hintWidth, height: 28)
        spaceKeycap.frame = NSRect(x: 0, y: 5, width: keycapWidth, height: 18)
        quickLookLabel.frame = NSRect(x: keycapWidth + 5, y: 6, width: quickLookWidth, height: 18)
        // CanvasWindowController clears the tree directly (`folderTree.clear()`), so page 26 is re-read here too.
        applyStatusText()
        let statusRight = (keyboardHint.isHidden
            ? (searchField.isHidden ? searchButton.frame.minX : searchField.frame.minX)
            : keyboardHint.frame.minX) - 16
        // grid-light.html .grid-file-status: the name text starts at x 63 and hugs its text up to 240/180/140/90px; the
        // count text follows after a 12px (7px through 800px) gap. These are text boxes: an NSTextField draws 2pt inside
        // its frame, so each frame is its cell width. The image count never truncates; a long search summary does,
        // after the name's slot. A hidden count reserves nothing.
        let inset: CGFloat = 2
        let available = max(0, statusRight - (63 - inset))
        let countGap: CGFloat = (footer.bounds.width <= 800 ? 7 : 12) - 2 * inset
        let fileMaxWidth: CGFloat = (footer.bounds.width <= 480 ? 90
            : footer.bounds.width <= 720 ? 140 : footer.bounds.width <= 800 ? 180 : 240) + 2 * inset
        var fileWidth = min(fileMaxWidth, Self.cellWidth(currentFileStatus), available)
        var countWidth: CGFloat = 0
        if !searchStatus.isHidden {
            let countNeed = Self.cellWidth(searchStatus)
            if countIsSearchSummary && !showsCountStatus {
                countWidth = min(countNeed, max(0, available - fileWidth - countGap))
            } else {
                countWidth = min(countNeed, available)
                fileWidth = min(fileWidth, max(0, available - countWidth - countGap))
            }
        }
        let fileHeight = ceil(currentFileStatus.intrinsicContentSize.height)
        currentFileStatus.frame = NSRect(x: 63 - inset, y: ((footer.bounds.height - fileHeight) / 2).rounded(),
                                         width: fileWidth, height: fileHeight)
        let countHeight = ceil(searchStatus.intrinsicContentSize.height)
        searchStatus.frame = NSRect(x: currentFileStatus.frame.maxX + countGap,
                                    y: ((footer.bounds.height - countHeight) / 2).rounded(),
                                    width: countWidth, height: countHeight)
        emptyState.frame = mainContent.bounds
        let centerX = emptyState.bounds.midX
        let centerY = emptyState.bounds.midY
        // search-empty.html: centered flex column; h2 margin-top 18,
        // p margin-top 9 and line-height 1.7 × 13, actions margin-top 18.
        let titleGap: CGFloat = 18
        let detailGap: CGFloat = 9
        let actionGap: CGFloat = 18
        let iconHeight: CGFloat = 32
        let titleHeight: CGFloat = 25
        let detailHeight: CGFloat = 22.1
        let clearHeight: CGFloat = 30
        let groupHeight = iconHeight + titleGap + titleHeight + detailGap + detailHeight + actionGap + clearHeight
        let groupTop = centerY + groupHeight / 2
        emptyIcon.frame = NSRect(x: centerX - 16, y: groupTop - iconHeight, width: 32, height: iconHeight)
        let emptyWidth = min(360, max(0, emptyState.bounds.width - 48))
        emptyTitle.frame = NSRect(x: centerX - emptyWidth / 2,
                                  y: emptyIcon.frame.minY - titleGap - titleHeight,
                                  width: emptyWidth, height: titleHeight)
        emptyDetail.frame = NSRect(x: centerX - emptyWidth / 2,
                                   y: emptyTitle.frame.minY - detailGap - detailHeight,
                                   width: emptyWidth, height: detailHeight)
        clearSearchButton.frame = NSRect(x: max(0, centerX - 65),
                                         y: emptyDetail.frame.minY - actionGap - clearHeight,
                                         width: 130, height: clearHeight)
        favoritesButton.frame = NSRect(x: 12, y: max(0, sidebar.bounds.height - 54),
                                       width: max(0, sidebar.bounds.width - 24), height: 32)
        recentsButton.frame = NSRect(x: 12, y: max(0, favoritesButton.frame.minY - 35),
                                     width: max(0, sidebar.bounds.width - 24), height: 32)
        folderName.frame = NSRect(x: 14, y: max(0, recentsButton.frame.minY - 25),
                                  width: max(0, sidebar.bounds.width - 28), height: 20)
        folderTree.frame = NSRect(x: 0, y: 0, width: sidebar.bounds.width,
                                  height: max(0, recentsButton.frame.minY - 4))
        // The tree's compact rule follows the window, which is wider than a viewer-mode shell.
        folderTree.viewportWidth = if mode == .viewerSidebar, let superview { superview.bounds.width } else { bounds.width }
        sidebarRule.frame = NSRect(x: max(0, sidebar.bounds.width - 1), y: 0, width: 1,
                                   height: sidebar.bounds.height)
        divider.frame = NSRect(x: max(0, sidebar.bounds.width - 5), y: 0, width: 5,
                               height: sidebar.bounds.height)
        divider.setAccessibilityValue(NSNumber(value: Double(main.minX)))
        // viewer-options.css `.grid-tools-panel`: right 12, bottom 50, width 280, max-width calc(100vw − 24px).
        let panelWidth = max(0, min(280, bounds.width - 24))
        displayPanel.frame = NSRect(x: bounds.width - 12 - panelWidth, y: 50, width: panelWidth,
                                    height: displayPanel.fittingHeight())
        if lastMainFrame != main {
            lastMainFrame = main
            onMainFrameChange?(main)
            // #444: the viewer re-lays out beside the new main frame and may move the sidebar's limit (a narrower
            // window). AppKit drops a layout request made inside layout(), so lay out again at the new edge, once: the
            // second pass ends there even if its callback moves the limit again.
            if mainFrame != main, !isRelayingOut {
                isRelayingOut = true
                layout()
                isRelayingOut = false
                return
            }
        }
        onMainContentLayout?()
    }
    /// The width an NSTextField needs to draw its string untruncated: its text plus the cell's padding.
    private static func cellWidth(_ field: NSTextField) -> CGFloat {
        ceil(field.cell!.cellSize.width)
    }
    @objc private func toggleFromButton() { toggleSidebar() }
    public func toggleSidebar() {
        var value = preferencesStore.value
        // The grid's sidebar only: the viewer's has its own state in the Session (owner decision 2026-11-04).
        if value.gridSidebarVisible, window?.firstResponder === divider { window?.makeFirstResponder(toggleButton) }
        value.gridSidebarVisible.toggle()
        preferencesStore.value = value
        refreshToggleLabel()
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateKeyViewLoop()
    }
    public func resizeSidebar(to width: CGFloat) {
        guard width.isFinite else { return }
        var value = preferencesStore.value
        value.gridSidebarWidth = Double(min(320, max(160, width)))
        preferencesStore.value = value
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    private func setLiveSidebarWidth(_ width: CGFloat) {
        guard width.isFinite else { return }
        liveSidebarWidth = min(320, max(160, width))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    private func finishSidebarDrag() {
        defer { dragStartWidth = nil; liveSidebarWidth = nil }
        if let liveSidebarWidth { resizeSidebar(to: liveSidebarWidth) }
    }
    public func linkKeyViews(from anchor: NSView) {
        focusAnchor = anchor
        focusTail = nil
        updateKeyViewLoop()
    }
    public func linkKeyViews(from first: NSView, through last: NSView) {
        focusAnchor = first
        focusTail = last
        updateKeyViewLoop()
    }
    private var footerKeyViews: [NSView] {
        var views: [NSView] = [toggleButton]
        if preferencesStore.value.gridSidebarVisible {
            views.append(divider)
            if !folderTree.isHidden { views.append(contentsOf: folderTree.rows) }
        }
        views.append(contentsOf: pageKeyViews)
        if footerActionsEnabled {
            views.append(searchField.isHidden ? searchButton : searchField)
            views.append(sortButton)
        }
        // #114: the Display button is never a dead control, so it stays in the loop with footer actions off.
        views.append(displayButton)
        if footerActionsEnabled && !emptyState.isHidden { views.append(clearSearchButton) }
        return views
    }
    public var firstFooterKeyView: NSView { footerKeyViews[0] }
    public var lastFooterKeyView: NSView { footerKeyViews[footerKeyViews.count - 1] }
    public func adjacentFooterKeyView(to view: NSView, reverse: Bool) -> NSView? {
        let views = footerKeyViews
        guard let index = views.firstIndex(where: { $0 === view }) else { return nil }
        let next = index + (reverse ? -1 : 1)
        return views.indices.contains(next) ? views[next] : nil
    }
    private var pageKeyViews: [NSView] { emptyFolderView.isHidden ? [] : emptyFolderView.keyViews }
    private func updateKeyViewLoop() {
        // The viewer's loop (canvas → tools → sidebar) is linked by ViewerStateFocus.
        guard mode == .grid, let focusAnchor else { return }
        (focusTail ?? focusAnchor).nextKeyView = toggleButton
        let page = pageKeyViews
        let nextAction: NSView = footerActionsEnabled ? (searchField.isHidden ? searchButton : searchField)
            : page.first ?? displayButton
        for (index, view) in page.enumerated() {
            view.nextKeyView = page.indices.contains(index + 1) ? page[index + 1] : displayButton
        }
        let treeRows: [NSView] = preferencesStore.value.gridSidebarVisible && !folderTree.isHidden ? folderTree.rows : []
        toggleButton.nextKeyView = preferencesStore.value.gridSidebarVisible ? divider : nextAction
        divider.nextKeyView = treeRows.first ?? nextAction
        for (index, row) in treeRows.enumerated() {
            row.nextKeyView = treeRows.indices.contains(index + 1) ? treeRows[index + 1] : nextAction
        }
        searchButton.nextKeyView = sortButton
        searchField.nextKeyView = sortButton
        sortButton.nextKeyView = displayButton
        displayButton.nextKeyView = footerActionsEnabled && !emptyState.isHidden ? clearSearchButton : focusAnchor
        clearSearchButton.nextKeyView = focusAnchor
    }
    /// Footer search is offered: not while reading, and not on page 22 (its search and sort are disabled).
    public var searchAvailable: Bool { footerActionsEnabled }
    public func focusSearch() {
        guard footerActionsEnabled else { return }
        searchButton.isHidden = true
        searchField.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateKeyViewLoop()
        window?.makeFirstResponder(searchField)
    }
    public func preserveRestoredSearchEditorThroughMenuDispatch() {
        preserveRestoredSearchEditor = true
        DispatchQueue.main.async { [weak self] in self?.preserveRestoredSearchEditor = false }
    }
    @objc private func openSearchFromButton() { focusSearch() }
    private func collapseSearch() {
        searchField.isHidden = true
        searchButton.isHidden = false
        searchButton.state = searchField.stringValue.isEmpty ? .off : .on
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateKeyViewLoop()
    }
    public func controlTextDidEndEditing(_ obj: Notification) {
        // A menu key equivalent can restore this editor before AppKit delivers its old end-editing callback.
        if preserveRestoredSearchEditor,
           window?.firstResponder === searchField || window?.firstResponder === searchField.currentEditor() {
            preserveRestoredSearchEditor = false
            return
        }
        preserveRestoredSearchEditor = false
        collapseSearch()
    }
    public func setFooterActionsEnabled(_ enabled: Bool) {
        footerActionsRequested = enabled
        if !enabled { searchEmptyRequested = false }
        applyFooterState()
    }
    /// Page 22 disables footer search and sort and hides page 23 until it leaves.
    private func applyFooterState() {
        let enabled = footerActionsRequested && emptyFolderView.isHidden && !isReadFailed
        footerActionsEnabled = enabled
        infoButton.isEnabled = !isReadFailed && comingSoonEntries[ObjectIdentifier(infoButton)]?.isEnabled != false
        searchField.isEnabled = enabled
        searchButton.isEnabled = enabled
        sortButton.isEnabled = enabled
        emptyState.isHidden = !searchEmptyRequested || !emptyFolderView.isHidden
        emptyState.setAccessibilityHidden(!enabled || emptyState.isHidden)
        updateKeyViewLoop()
    }
    public func setSearchTerm(_ term: String) {
        searchField.stringValue = term
        searchButton.state = term.isEmpty ? .off : .on
        if term.isEmpty {
            countText = ""
            countIsSearchSummary = false
            if applyStatusText() { needsLayout = true }
        }
    }
    public func setCurrentFile(_ name: String) {
        currentFileName = name
        applyStatusText()
        needsLayout = true
    }
    /// folder-loading.html: the empty name slot, then `Reading…` in the count's place. The page's `—` renders 7px wide
    /// (Avenir Next); SF's en dash has that width.
    public func setReadingStatus(_ reading: Bool) {
        isReading = reading
        if reading { isReadFailed = false }
        applyReadStatus()
    }
    /// folder-loading.html `?case=failed`: `–` in the name slot, 「读取未完成」 in the count's, `—` for the folder's
    /// count; search, sort and information are unavailable while nothing complete is shown.
    public func setReadFailedStatus(_ failed: Bool) {
        isReadFailed = failed
        if failed { isReading = false }
        applyReadStatus()
    }
    private func applyReadStatus() {
        folderTree.showsZeroForUnknownCurrent = false
        folderTree.showsDashForCurrent = isReadFailed
        applyStatusText()
        applyFooterState()
        needsLayout = true
    }
    /// The name and count slots, by precedence: a read's status, page 26 (`–` / Unavailable), page 22 (`–` /
    /// `0 images`, including during search), then the stored name and count. The stored values are never overwritten, so leaving a page
    /// shows the latest ones. Layout calls this too, so unchanged values are not reassigned; returns whether any changed.
    @discardableResult private func applyStatusText() -> Bool {
        let showsDash = showsReadStatus || showsLostAccess || !emptyFolderView.isHidden
        let name = showsDash ? "—" : currentFileName
        let count = isReading ? String(localized: "Reading…")
            : isReadFailed ? String(localized: "Read incomplete")
            : showsLostAccess ? String(localized: "Unavailable")
            : !emptyFolderView.isHidden ? String(format: String(localized: "%lld images"), 0) : countText
        let countHidden = footer.bounds.width <= 480 || count.isEmpty
        let changed = currentFileStatus.stringValue != name || currentFileStatus.isHidden != name.isEmpty
            || searchStatus.stringValue != count || searchStatus.isHidden != countHidden
        if currentFileStatus.stringValue != name { currentFileStatus.stringValue = name }
        if currentFileStatus.isHidden != name.isEmpty { currentFileStatus.isHidden = name.isEmpty }
        if searchStatus.stringValue != count { searchStatus.stringValue = count }
        if searchStatus.isHidden != countHidden { searchStatus.isHidden = countHidden }
        return changed
    }
    public func setSearchStatus(resultCount: Int, term: String) {
        countText = term.isEmpty
            ? String(format: String(localized: "%lld images"), resultCount)
            : String(format: String(localized: "Search: %@ · %lld results"), term, resultCount)
        countIsSearchSummary = !term.isEmpty
        applyStatusText()
        searchButton.state = term.isEmpty ? .off : .on
        needsLayout = true
    }
    private func setEmptyDetailText(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.minimumLineHeight = 22.1
        paragraph.maximumLineHeight = 22.1
        emptyDetail.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: DesignColor.textSecondary.nsColor,
            .paragraphStyle: paragraph,
        ])
    }
    public func showSearchEmpty(_ visible: Bool, term: String = "") {
        if visible { mainContent.addSubview(emptyState, positioned: .above, relativeTo: nil) }
        if visible { setEmptyDetailText(String(format: String(localized: "No images with “%@” in their filename."), term)) }
        else { setEmptyDetailText(String(localized: "Try another filename or clear the search.")) }
        searchEmptyRequested = visible
        applyFooterState()
    }
    public var searchEmptyVisible: Bool { !emptyState.isHidden }
    public func controlTextDidChange(_ obj: Notification) { onSearchChange?(searchField.stringValue) }
    public func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { clearSearch() }
    }
    @objc func searchFieldAction() {
        if searchField.stringValue.isEmpty { clearSearch() }
        else { onSearchChange?(searchField.stringValue) }
    }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        clearSearch()
        return true
    }
    @objc private func clearFromButton() { clearSearch() }
    private func clearSearch() {
        searchField.stringValue = ""
        if !searchField.isHidden { window?.makeFirstResponder(searchButton) }
        collapseSearch()
        searchStatus.isHidden = true
        onSearchChange?("")
        onClearSearch?()
    }
    @objc private func showSortMenu() {
        onOpenSortMenu?(sortButton, makeSortMenu())
    }
    public func makeSortMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Sort By"))
        for key in FolderSortKey.allCases { addSortItem(.sort(key), to: menu) }
        menu.addItem(.separator())
        for direction in FolderSortDirection.allCases { addSortItem(.direction(direction), to: menu) }
        return menu
    }
    private func addSortItem(_ action: FolderMenuAction, to menu: NSMenu) {
        let item = menu.addItem(withTitle: String(localized: String.LocalizationValue(action.titleKey)),
                                action: #selector(selectSort(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.setAccessibilityIdentifier(action.accessibilityIdentifier)
        if let conditions = sortConditions?() {
            switch action {
            case .sort(let key): item.state = conditions.sort == key ? .on : .off
            case .direction(let direction): item.state = conditions.direction == direction ? .on : .off
            default: break
            }
        }
    }
    @objc private func selectSort(_ item: NSMenuItem) {
        guard let action = item.representedObject as? FolderMenuAction else { return }
        onSort?(action)
    }
    public func entryPoint(for button: NSButton) -> EntryPoint? {
        comingSoonEntries[ObjectIdentifier(button)]
    }
    private func configureComingSoon(_ button: NSButton, entry: EntryPoint, title: String, identifier: String,
                                     systemImage: String, iconOnly: Bool = false) {
        let label = "\(title) · \(entry.accessibilityLabel(for: .preferred))"
        comingSoonEntries[ObjectIdentifier(button)] = entry
        button.title = iconOnly ? "" : title
        button.font = .systemFont(ofSize: 12)
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.isEnabled = entry.isEnabled
        button.refusesFirstResponder = !entry.isFocusable
        button.keyEquivalent = entry.keyEquivalent ?? ""
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }
    /// Page 15 (#114): the footer Display button opens the display popover; pressed while it is open.
    private func configureDisplayButton() {
        let label = String(localized: "Display and Appearance")
        displayButton.setButtonType(.pushOnPushOff)
        displayButton.title = ""
        displayButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        displayButton.imagePosition = .imageOnly
        displayButton.imageScaling = .scaleProportionallyDown
        displayButton.isBordered = false
        displayButton.contentTintColor = .secondaryLabelColor
        displayButton.wantsLayer = true
        displayButton.layer?.cornerRadius = DesignMetrics.radii["control"]!
        displayButton.toolTip = label
        displayButton.setAccessibilityLabel(label)
        displayButton.setAccessibilityIdentifier("grid.display.button")
        displayButton.target = self
        displayButton.action = #selector(toggleDisplayPanelFromButton)
        refreshDisplayButton()
    }
    @objc private func toggleDisplayPanelFromButton() { setDisplayPanelOpen(!isDisplayPanelOpen) }
    /// Opening focuses the slider; closing returns focus to the Display button. An outside click closes without
    /// moving focus that is already outside the panel, so the click's target can take it.
    public func setDisplayPanelOpen(_ open: Bool) { setDisplayPanelOpen(open, restoringFocus: true) }
    private func setDisplayPanelOpen(_ open: Bool, restoringFocus: Bool) {
        if open && !isDisplayPanelOpen {
            displayPanel.reflect(preferencesStore.value)
            addSubview(displayPanel, positioned: .above, relativeTo: nil)
            needsLayout = true
            layoutSubtreeIfNeeded()
            window?.makeFirstResponder(displayPanel.sizeSlider)
        } else if !open && isDisplayPanelOpen {
            let focusInPanel = (window?.firstResponder as? NSView)?.isDescendant(of: displayPanel) == true
            displayPanel.removeFromSuperview()
            if restoringFocus || focusInPanel { window?.makeFirstResponder(displayButton) }
        }
        refreshDisplayButton()
    }
    /// Window key rule while the panel is open: `true` consumed, `false` left to AppKit, `nil` not the panel's key.
    /// Esc closes the panel from any focus before the Inspector or grid sees it; Tab inside the panel walks its loop.
    public func routeDisplayPanelKey(_ event: NSEvent, firstResponder: NSResponder?) -> Bool? {
        guard isDisplayPanelOpen, !isHiddenOrHasHiddenAncestor,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        if event.keyCode == 53 {
            setDisplayPanelOpen(false)
            return true
        }
        if event.keyCode == 48, (firstResponder as? NSView)?.isDescendant(of: displayPanel) == true { return false }
        return nil
    }
    /// A mouse-down outside the open panel closes it; the click still reaches its target. viewer-options.js closes
    /// the panel on an outside pointer-down; the Display button keeps its own toggle.
    public func dismissDisplayPanel(forMouseDown event: NSEvent) {
        guard isDisplayPanelOpen, let window, event.windowNumber == window.windowNumber else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !displayPanel.frame.contains(point), !displayButton.convert(displayButton.bounds, to: self).contains(point)
        else { return }
        setDisplayPanelOpen(false, restoringFocus: false)
    }
    private func refreshDisplayButton() {
        displayButton.state = isDisplayPanelOpen ? .on : .off
        displayButton.setAccessibilityValue(NSNumber(value: isDisplayPanelOpen ? 1 : 0))
        refreshAppearance()
    }
    /// The store is the one source: a change from this panel, Settings or elsewhere reaches the grid and the panel.
    public func preferencesDidChange(_ preferences: DisplayPreferences) {
        displayPanel.reflect(preferences)
        let options = GridDisplayOptions(preferences)
        guard options != gridDisplayOptions else { return }
        gridDisplayOptions = options
        for case let grid as GridBrowserView in mainContent.subviews {
            optionedGrids.add(grid)
            grid.displayOptions = options
        }
    }
    private func refreshToggleLabel() {
        let label = String(localized: preferencesStore.value.gridSidebarVisible ? "Hide sidebar" : "Show sidebar")
        toggleButton.toolTip = label
        toggleButton.setAccessibilityLabel(label)
        toggleButton.state = preferencesStore.value.gridSidebarVisible ? .on : .off
        refreshAppearance()
    }
}
