import MadoApplication
import MadoCore

/// Coordinates a watched snapshot with the grid's current search projection.
@MainActor public enum GridWatchedSearchRefresh {
    public static func apply(_ source: FolderSnapshot, session: ViewerSession,
        search: GridSearchState, scheduler: GridSearchProjectionScheduler,
        grid: GridBrowserView, shell: GridShellView, gridVisible: Bool,
        onReconciled: (() -> Void)? = nil) {
        scheduler.cancel()
        let filtered = search.project(source)
        let version = PreviewSourceVersion(source.version.generation)
        if gridVisible {
            // Reconcile against the complete order first, so a deleted Current Item keeps its nearest survivor.
            session.updateItems(source.navigationEntries.map(\.itemID), sourceVersion: version)
            let current = search.currentItemID(in: filtered, currentItemID: session.selection.currentItemID)
            session.updateItems(filtered.navigationEntries.map(\.itemID), sourceVersion: version)
            restoreGrid(source, session: session, search: search, grid: grid, shell: shell)
            grid.setCurrentItemID(current)
            if let current { session.focus(current) }
        } else {
            // A preview opened from a searched grid must never regain hidden items during refresh.
            session.updateItems(filtered.navigationEntries.map(\.itemID), sourceVersion: version)
        }
        onReconciled?()
    }

    public static func restoreGrid(_ source: FolderSnapshot, session: ViewerSession,
        search: GridSearchState, grid: GridBrowserView, shell: GridShellView) {
        let filtered = search.project(source)
        grid.display(filtered, selection: session.selection)
        shell.showSearchEmpty(!search.term.isEmpty && filtered.navigationEntries.isEmpty, term: search.term)
        shell.setSearchStatus(resultCount: filtered.navigationEntries.count, term: search.term)
    }
}
