import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

/// App seam: grid-light.html and GRID-02 pending Current Item and Cancel Reading restore.
@Test @MainActor func completedGridPresentationRestoresPendingCurrentAndCancelOffsetSynchronously() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-complete-presentation")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<80).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
    let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.layoutSubtreeIfNeeded()
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView())
    let current = entries[40].itemID
    presentation.showCompletedGrid(snapshot, selection: BrowserSelection(),
        currentItemID: current, offset: nil)
    #expect(grid.currentItemID == current) // single-image Esc after folder scan
    grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 2),
        entries: [], isComplete: false), selectedItemID: nil)
    let offset = NSPoint(x: 0, y: 137)
    presentation.showCompletedGrid(snapshot, selection: BrowserSelection(),
        currentItemID: current, offset: offset)
    #expect(grid.currentItemID == current) // Cancel Reading
    #expect(grid.contentOffset == offset)
}
