import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func gridEmptySpaceDeselectionKeepsViewAndModelInSync() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-deselect")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entry = FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: root)
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [entry], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let session = ViewerSession()
    session.beginBrowsing(items: [entry.itemID], sourceVersion: .init(1), scrollAnchor: entry.itemID)
    session.select(entry.itemID)
    grid.display(snapshot, selectedItemID: entry.itemID)
    grid.activate(currentItemID: entry.itemID)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty == false)
    grid.onDeselect = {
        if let current = session.selection.currentItemID { session.select(current, modifier: .command) }
    }

    grid.collectionView.deselectAll(nil)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)
    #expect(session.selection.selectedItemIDs.isEmpty)
    #expect(session.selection.currentItemID == entry.itemID)
    #expect(grid.currentItemID == entry.itemID)

    let selected = session.selection.currentItemID.flatMap {
        session.selection.selectedItemIDs.contains($0) ? $0 : nil
    }
    grid.display(snapshot, selectedItemID: selected)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)
    #expect(session.selection.selectedItemIDs.isEmpty)
}
