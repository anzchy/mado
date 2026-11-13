import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func singleImageEscDestinationUsesRootIdentityAndCurrentWithoutSelection() {
    _ = NSApplication.shared
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: URL(fileURLWithPath: "/authorized"))
    let file = root.url.appendingPathComponent("nested/image.jpg")
    let destination = GridSingleImageReturnPolicy.destination(for: file, root: root)
    #expect(destination.folder == file.deletingLastPathComponent())
    #expect(destination.currentItemID == FolderEntry(url: file, root: root).itemID)

    let other = FolderEntry(url: file.deletingLastPathComponent().appendingPathComponent("other.jpg"), root: root)
    let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: destination.folder, generation: 1),
        entries: [other, FolderEntry(url: file, root: root)], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    grid.display(snapshot, selectedItemID: nil)
    grid.activate(currentItemID: destination.currentItemID)
    #expect(grid.currentItemID == destination.currentItemID)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)
}
