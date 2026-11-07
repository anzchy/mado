import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

@Test @MainActor func gridReadingShowsNoCellsUntilCompleteAndCancelRestoresPriorPresentation() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-reading")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entries = [FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: root),
        FolderEntry(url: folder.appendingPathComponent("B.jpg"), root: root)]
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    let partial = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: entries, isComplete: false)
    grid.display(partial, selectedItemID: nil)
    #expect(grid.collectionView(grid.collectionView, numberOfItemsInSection: 0) == 0)

    let complete = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    grid.display(complete, selectedItemID: nil)
    grid.activate()
    #expect(grid.collectionView(grid.collectionView, numberOfItemsInSection: 0) == 2)
    #expect(grid.currentItemID == entries[0].itemID)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)

    let scene = StatesScene()
    scene.state.display(.readingFolder)
    #expect(scene.state.showsProgress)
    #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.cancel-folder"])
    var restored = 0
    scene.state.onCancelFolderReading = { restored += 1 }
    scene.state.buttons.first?.performClick(nil)
    #expect(restored == 1)
    scene.window.close()
}
