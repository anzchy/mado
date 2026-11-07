import MadoApplication
import MadoCore

/// Presents a direct filename-search projection in the current grid window.
@MainActor public enum GridSearchReconciler {
    public static func present(_ filtered: FolderSnapshot, source: FolderSnapshot,
        session: ViewerSession, search: GridSearchState, grid: GridBrowserView,
        shell: GridShellView, onReconciled: (() -> Void)? = nil) {
        let current = search.currentItemID(in: filtered, currentItemID: grid.currentItemID)
        session.updateItems(filtered.navigationEntries.map(\.itemID),
            sourceVersion: .init(source.version.generation))
        grid.display(filtered, selection: session.selection)
        grid.setCurrentItemID(current)
        if let current { session.focus(current) }
        shell.showSearchEmpty(!search.term.isEmpty && filtered.navigationEntries.isEmpty, term: search.term)
        shell.setSearchStatus(resultCount: filtered.navigationEntries.count, term: search.term)
        onReconciled?()
    }
}
