import AppKit
import PicseeApplication
import PicseeCore

/// One owner for which surface the window shows: viewer (canvas, chrome, states), Reading State, or grid.
@MainActor public final class GridViewerPresentation {
    private let canvas: NSView, chrome: NSView, state: NSView, grid: NSView, inspector: NSView
    private let shell: GridShellView?
    public init(canvas: NSView, chrome: NSView, state: NSView, grid: NSView, inspector: NSView,
                shell: GridShellView? = nil) {
        self.canvas = canvas; self.chrome = chrome; self.state = state; self.grid = grid; self.inspector = inspector
        self.shell = shell
        // The viewer's sidebar has no shell state surface; a divider drag re-lays out the viewer beside it.
        // The shell never holds the chrome, so the chrome may keep it.
        if let shell { (chrome as? ViewerChromeOverlay)?.trailingKeyViews = { shell.viewerSidebarKeyViews } }
        shell?.onViewerSidebarKeyViewsChange = { [weak canvas, weak chrome, weak state] in
            guard let canvas, let chrome = chrome as? ViewerChromeOverlay, let state = state as? ViewerStateHost else { return }
            state.linkKeyViews(to: canvas, chrome: chrome)
        }
        shell?.onMainFrameChange = { [weak self, weak shell, weak state] main in
            guard let shell, !shell.isHidden else { return }
            if shell.mode == .viewerSidebar {
                if let self { layoutInspector(visible: inspectorVisible) }
                return
            }
            guard let state, !state.isHidden, let parent = state.superview else { return }
            state.frame = shell.convert(main, to: parent)
        }
    }
    public var isGridVisible: Bool { !grid.isHidden }
    /// #444: the window can show the folder sidebar beside the viewer (a preview entered from a folder grid).
    public var viewerSidebarAvailable = false
    private var inspectorVisible = false
    private func focusCanvas() {
        canvas.window?.makeFirstResponder(canvas)
        shell?.session?.updateFocus(.canvas)
    }
    /// Page 14's pods need 16 + 104 + 8 + 174 + 16 pt of canvas; the sidebar never takes that from the viewer.
    static let viewerPodClearance: CGFloat = 318
    /// The sidebar's own minimum, the grid divider's clamp; a narrower viewer sidebar is not laid out at all.
    static let minimumViewerSidebarWidth: CGFloat = 160
    /// Shows the viewer's sidebar when the Session asks for it and the window leaves room beside the pods; returns its
    /// width (0 while hidden). A sidebar that hides while it holds keyboard focus hands focus to the canvas.
    private func applyViewerSidebarVisibility(_ shell: GridShellView, contentWidth: CGFloat) -> CGFloat {
        shell.viewerSidebarLimit = contentWidth - Self.viewerPodClearance
        let width = shell.sidebarWidth
        let show = viewerSidebarAvailable && shell.session?.isViewerSidebarShown == true
            && width >= Self.minimumViewerSidebarWidth
        if !show, let responder = canvas.window?.firstResponder as? NSView, responder.isDescendant(of: shell) {
            focusCanvas()
        }
        shell.isHidden = !show
        shell.setAccessibilityHidden(!show)
        return show ? width : 0
    }
    public func layoutInspector(visible: Bool) {
        guard let parent = canvas.superview else { return }
        let bounds = parent.bounds
        let panelWidth: CGFloat = visible && !InspectorPanelLayout.overlaysContent(at: bounds.width)
            ? min(InspectorPanelLayout.width(for: bounds.width), bounds.width) : 0
        let contentWidth = max(0, bounds.width - panelWidth)
        let content = NSRect(x: bounds.minX, y: bounds.minY, width: contentWidth, height: bounds.height)
        inspectorVisible = visible
        if let shell, shell.mode == .viewerSidebar {
            let sidebar = applyViewerSidebarVisibility(shell, contentWidth: contentWidth)
            if !shell.isHidden {
                shell.frame = NSRect(x: bounds.minX, y: bounds.minY, width: sidebar, height: max(0, bounds.height - 28))
                shell.layoutSubtreeIfNeeded()
            }
            let viewer = NSRect(x: bounds.minX + sidebar, y: bounds.minY, width: contentWidth - sidebar, height: bounds.height)
            canvas.frame = viewer
            chrome.frame = viewer
            state.frame = viewer
            inspector.frame = InspectorPanelLayout.frame(in: bounds, grid: !grid.isHidden)
            return
        }
        canvas.frame = content
        chrome.frame = content
        if let shell {
            shell.frame = NSRect(x: bounds.minX, y: bounds.minY, width: contentWidth,
                                 height: max(0, bounds.height - 28))
            shell.layoutSubtreeIfNeeded()
            if !state.isHidden && !shell.isHidden {
                state.frame = shell.convert(shell.mainFrame, to: parent)
            } else if shell.isHidden {
                state.frame = content
            }
        } else {
            state.frame = content
        }
        inspector.frame = InspectorPanelLayout.frame(in: bounds, grid: !grid.isHidden)
    }
    /// Begins a folder preview from the visible grid's ordered snapshot.
    public func beginPreview(_ session: ViewerSession, snapshot: FolderSnapshot?, scrollAnchor: ItemID?) {
        session.beginBrowsing(items: snapshot?.navigationEntries.map(\.itemID) ?? [],
            sourceVersion: .init(snapshot?.version.generation ?? 0), scrollAnchor: scrollAnchor)
    }
    public func showViewer() {
        // #444: hiding the focused grid or footer hands focus to its next key view, which is now the sidebar beside
        // the viewer, and the App window then refuses the canvas. Focus the canvas before anything in the grid hides.
        if let window = canvas.window, let focused = window.firstResponder as? NSView,
           focused === grid || focused.isDescendant(of: grid) || shell.map({ shell in
               [shell.mainContent, shell.footer, shell.displayPanel].contains { focused.isDescendant(of: $0) } }) == true {
            canvas.isHidden = false
            window.makeFirstResponder(canvas)
        }
        shell?.setReadingStatus(false)
        shell?.setMode(.viewerSidebar)
        state.autoresizingMask = [.width, .height]
        if let parent = state.superview { state.frame = parent.bounds }
        (grid as? GridBrowserView)?.setThumbnailsActive(false)
        grid.isHidden = true
        grid.setAccessibilityHidden(true)
        canvas.isHidden = false
        chrome.isHidden = false
        setStateSurface(.viewer)
        // Hide or show the viewer's sidebar even before the window is laid out (no parent: no room, so hidden).
        if let shell {
            _ = applyViewerSidebarVisibility(shell, contentWidth: canvas.superview.map { $0.bounds.width } ?? 0)
            layoutInspector(visible: inspectorVisible)
        }
    }
    public func showGrid(reading: Bool) {
        if let shell, shell.mode == .viewerSidebar {
            // The viewer narrowed the shell to its sidebar; the grid shell spans the content beside the inspector.
            // Restore that frame first: setMode lays out, and a grid laid out at the sidebar's width gets a zero item width.
            if let parent = shell.superview {
                shell.frame = NSRect(x: parent.bounds.minX, y: parent.bounds.minY, width: canvas.frame.maxX - parent.bounds.minX,
                                     height: max(0, parent.bounds.height - 28))
            }
            shell.setMode(.grid)
        }
        shell?.isHidden = false
        shell?.setAccessibilityHidden(false)
        shell?.setFooterActionsEnabled(!reading)
        if let grid = grid as? GridBrowserView {
            shell?.linkKeyViews(from: grid.collectionView)
            grid.onCurrentFileChange = { [weak shell] name in shell?.setCurrentFile(name ?? "") }
            shell?.setCurrentFile(grid.currentItemID.flatMap { grid.entry(for: $0) }?.url.lastPathComponent ?? "")
            shell?.setReadingStatus(reading)
        }
        shell?.layoutSubtreeIfNeeded()
        if reading, let shell, let parent = state.superview {
            state.autoresizingMask = []
            state.frame = shell.convert(shell.mainFrame, to: parent)
        }
        canvas.isHidden = true
        chrome.isHidden = true
        inspector.isHidden = true
        grid.isHidden = reading
        (grid as? GridBrowserView)?.setThumbnailsActive(!reading)
        grid.setAccessibilityHidden(reading)
        setStateSurface(reading ? .gridReading : .grid)
    }
    private func setStateSurface(_ surface: ViewerStateHost.Surface) {
        if let host = state as? ViewerStateHost { host.surface = surface; return }
        state.isHidden = surface == .grid
        state.setAccessibilityHidden(state.isHidden)
    }
    /// A folder read that starts while the grid is shown (an Include Subfolders rescan) covers it with the Reading State.
    public func showReadingOverGrid(_ reading: Bool) -> Bool {
        guard reading, isGridVisible else { return false }
        showGrid(reading: true)
        layoutInspector(visible: false)
        return true
    }
    /// A folder read that starts on the shell's reading or failed surface (Retry) shows the reading footer again.
    /// A viewer-entry read keeps the shell hidden.
    public func resumeReadingFooter(_ reading: Bool) {
        guard reading, let shell, shell.isGridSurface, grid.isHidden else { return }
        shell.setReadingStatus(true)
    }
    /// Restores the native grid after a preview with the Session's reconciled selection.
    public func restoreGrid(_ snapshot: FolderSnapshot, selection: BrowserSelection, offset: NSPoint?) {
        (grid as? GridBrowserView)?.display(snapshot, selection: selection)
        showGrid(reading: false)
        if let offset { (grid as? GridBrowserView)?.restoreContentOffset(offset) }
    }
    public func showCompletedGrid(_ snapshot: FolderSnapshot, selection: BrowserSelection,
                                  currentItemID: ItemID?, offset: NSPoint?) {
        guard let grid = grid as? GridBrowserView else { return }
        grid.display(snapshot, selection: selection)
        if let shell {
            shell.setSearchStatus(resultCount: snapshot.navigationEntries.count,
                term: shell.searchField.stringValue)
        }
        showGrid(reading: false)
        grid.activate(currentItemID: currentItemID)
        if let offset { grid.restoreContentOffset(offset) }
    }
    /// What Cancel Reading returns to.
    public func show(_ target: FolderEntryRestoreTarget) {
        if target == .grid { showGrid(reading: false) } else { showViewer() }
    }
}
