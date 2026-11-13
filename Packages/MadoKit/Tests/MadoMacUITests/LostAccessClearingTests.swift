import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor @Test(.timeLimit(.minutes(2))) func t229ClearingGridAndTreeRemovesPrivateSelectionRowsAndAccessibility() throws {
    _ = NSApplication.shared
    let snapshot = pinningSnapshot(count: 2, names: ["private-one.png", "private-two.png"])
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    grid.display(snapshot, selectedItemID: snapshot.entries[0].itemID)
    #expect(grid.displayedItemIDs.count == 2)
    grid.clearPresentation()
    #expect(grid.displayedItemIDs.isEmpty)
    #expect(grid.currentItemID == nil)
    #expect(grid.selection.selectedItemIDs.isEmpty)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)
    #expect(grid.collectionView.numberOfItems(inSection: 0) == 0)
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 600))
    let root = snapshot.version.folder
    tree.show(current: .init(url: root), parent: nil,
        children: [.init(url: root.appendingPathComponent("PrivateChild"))])
    let detachedRows = tree.rows
    #expect(detachedRows.count == 2)
    tree.clear()
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows.isEmpty)
    #expect(tree.guide.isHidden)
    #expect(detachedRows.allSatisfy { $0.superview == nil })
    tree.clear(); grid.clearPresentation()
    #expect(tree.rows.isEmpty && grid.displayedItemIDs.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229LostPageTwoActionFocusOrderSurvivesSidebarToggle() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.autorecalculatesKeyViewLoop = false
    defer { window.close() }
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 680),
        preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    let page = LostAccessStateView(frame: shell.mainContent.bounds)
    shell.mainContent.addSubview(page)
    page.display(cause: .unknown, text: .init(title: "Unable to Access This Folder",
        detail: "Choose this folder again.", waiting: "Waiting…", reselect: "Choose Folder Again…", chooseOther: "Choose Another Folder…"))
    shell.setFooterActionsEnabled(false)
    shell.linkKeyViews(from: page.reselectButton, through: page.chooseOtherButton)
    for _ in 0..<3 {
        #expect(window.makeFirstResponder(page.reselectButton))
        window.selectNextKeyView(nil)
        #expect(window.firstResponder === page.chooseOtherButton)
        window.selectPreviousKeyView(nil)
        #expect(window.firstResponder === page.reselectButton)
        shell.toggleSidebar()
        shell.layoutSubtreeIfNeeded()
    }
    // Ordinary grid focus linking still replaces the complete recovery action group.
    shell.linkKeyViews(from: page.chooseOtherButton)
    #expect(window.makeFirstResponder(page.chooseOtherButton))
    window.selectNextKeyView(nil)
    #expect(window.firstResponder !== page.reselectButton)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229LostAccessSearchClearingErasesRetainedAccessibilityValues() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 680),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let query = "private-photo-name.png"
    shell.setSearchTerm(query)
    shell.setSearchStatus(resultCount: 0, term: query)
    shell.showSearchEmpty(true, term: query)
    let detail = try #require(shell.emptyStateDetail)
    #expect(detail.stringValue.contains(query))
    #expect(shell.searchStatus.stringValue.contains(query))
    // These are the exact public clearing inputs used by a Lost Access transition.
    shell.setSearchTerm("")
    shell.showSearchEmpty(false)
    #expect(shell.searchField.stringValue.isEmpty)
    #expect(shell.searchStatus.stringValue.isEmpty)
    #expect(!detail.stringValue.contains(query))
    #expect((detail.accessibilityValue() as? String)?.contains(query) != true)
    #expect((shell.searchStatus.accessibilityValue() as? String)?.contains(query) != true)
    #expect(shell.searchStatus.isHidden && !shell.searchEmptyVisible)
}
