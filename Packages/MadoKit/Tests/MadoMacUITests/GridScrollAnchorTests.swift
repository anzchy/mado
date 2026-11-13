import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func gridBatchesAndEscRestoreExactClipOffsetAndSectionInset() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-scroll")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entries = (0..<40).map { FolderEntry(url: folder.appendingPathComponent(String(format: "%02d.jpg", $0)), root: root) }
    func snapshot(_ generation: UInt64) -> FolderSnapshot {
        FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: generation),
            entries: entries, isComplete: true)
    }
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.display(snapshot(1), selectedItemID: nil)
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    let previewOffset = NSPoint(x: 0, y: 137)
    grid.restoreContentOffset(previewOffset)
    #expect(grid.contentOffset == previewOffset)

    grid.display(snapshot(2), selectedItemID: nil)
    #expect(grid.contentOffset == previewOffset)
    grid.restoreContentOffset(NSPoint(x: 0, y: 0))
    grid.restoreContentOffset(previewOffset)
    #expect(grid.contentOffset == previewOffset)
    let layout = grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
    #expect(layout?.sectionInset.top == 16)
    #expect(layout?.sectionInset.left == 16)
}
