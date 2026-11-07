import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

/// #522 / GRID-04 / GRID-05: reproduction only. Native arrow delivery is real;
/// the preview command below checks session semantics, not the App's Space bridge.
@Test(arguments: [1, 3]) @MainActor
func issue522SingleSelectionShiftRightTwiceExtendsContiguousRange(start: Int) throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-issue522")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<7).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let ids = entries.map(\.itemID)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[start])
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // NSWindow releases on close by default; ARC owns this fixture.
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = grid
    // Same public selection/focus callbacks used by CanvasWindowController.
    grid.onSelectionGesture = { id, modifier in
        session.select(id, modifier: modifier)
        return session.selection
    }
    grid.onSelect = { session.select($0) }
    grid.onCurrentChange = { session.focus($0) }
    grid.onDeselect = { session.clearSelection(); grid.synchronizeSelection(session.selection) }
    defer { grid.onDeselect = nil }
    grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true), selection: session.selection)
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    let tile = try #require(grid.collectionView.collectionViewLayout?
        .layoutAttributesForItem(at: IndexPath(item: start, section: 0))).frame
    let point = grid.collectionView.convert(NSPoint(x: tile.midX, y: tile.midY), to: nil)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    grid.collectionView.mouseDown(with: click)
    try #require(window.firstResponder === grid.collectionView)
    try #require(session.selection.selectedItemIDs == [ids[start]])
    try #require(grid.collectionView.selectionIndexPaths == [IndexPath(item: start, section: 0)])
    try #require(session.selection.anchorItemID == ids[start])

    for step in 1...2 {
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: Double(step), windowNumber: window.windowNumber, context: nil,
            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        window.sendEvent(right)
        let expected = Set(ids[start...start + step])
        let selectedIndexes = grid.collectionView.selectionIndexPaths.map(\.item).sorted()
        print("i522 start=\(start) step=\(step) native=\(selectedIndexes) session=\(ids.indices.filter { session.selection.selectedItemIDs.contains(ids[$0]) }) current=\(String(describing: session.selection.currentItemID.flatMap { ids.firstIndex(of: $0) })) anchor=\(String(describing: session.selection.anchorItemID.flatMap { ids.firstIndex(of: $0) }))")
        #expect(session.selection.selectedItemIDs == expected, "start=\(start) step=\(step): contiguous session selection")
        #expect(grid.selection.selectedItemIDs == expected, "start=\(start) step=\(step): contiguous grid selection")
        #expect(grid.collectionView.selectionIndexPaths == Set((start...start + step).map { IndexPath(item: $0, section: 0) }))
        #expect(session.selection.selectedItemIDs.count == step + 1)
        #expect(session.selection.anchorItemID == ids[start])
        #expect(grid.selection.anchorItemID == ids[start])
        #expect(session.selection.currentItemID == ids[start + step])
        #expect(grid.currentItemID == ids[start + step])
    }
    // No synthetic Space bridge: only the actual App can establish that wiring.
    #expect(CommandRouter().route(.preview, from: .key, to: session))
    #expect(session.previewSet?.itemIDs == Array(ids[start...start + 2]))
    #expect(CommandRouter().route(.escape, from: .key, to: session))
    #expect(session.selection.selectedItemIDs == Set(ids[start...start + 2]))
    #expect(session.selection.anchorItemID == ids[start])
}
