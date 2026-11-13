import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

@MainActor private final class I144MenuPresenter: GridContextMenuPresenting {
    var presented: (menu: NSMenu, point: NSPoint, view: NSView)?
    func present(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        presented = (menu, point, view)
    }
}

@Test @MainActor func imageContextMenuKeyboardEntryTargetsCurrentCell() throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/i144-grid"))
    let entries = (0..<6).map { FolderEntry(url: root.url.appendingPathComponent("\($0).png"), root: root) }
    let snapshot = FolderSnapshot(version: SnapshotVersion(rootID: root.id, folder: root.url, generation: 1),
                                  entries: entries, isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 800, height: 640))
    let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.display(snapshot, selection: BrowserSelection())
    grid.activate(currentItemID: entries[3].itemID)
    window.contentView?.layoutSubtreeIfNeeded()
    let presenter = I144MenuPresenter()
    grid.contextMenuPresenter = presenter
    var target: ItemID?
    grid.onContextMenu = { id in target = id; return GridImageContextMenu(onAction: { _ in }).menu }
    grid.showCurrentItemContextMenu()
    let captured = try #require(presenter.presented)
    #expect(target == entries[3].itemID)
    #expect(captured.view === grid.collectionView)
    let frame = grid.collectionView.frameForItem(at: 3)
    #expect(frame.contains(captured.point))
    presenter.presented = nil
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    grid.collectionView.keyDown(with: key)
    #expect(presenter.presented?.menu.items.first?.title == "Quick Look")
    #expect(target == entries[3].itemID)
    presenter.presented = nil
    let photo = try #require(grid.collectionView.item(at: IndexPath(item: 3, section: 0)) as? GridPhotoItem)
    #expect(photo.view.accessibilityPerformShowMenu())
    #expect(presenter.presented?.view === grid.collectionView)
}
