import Foundation
import Testing
import MadoCore
import MadoApplication

@Test @MainActor func imageContextMenuPreviewKeepsClickedStartAndCapturedSelectionRange() throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/i144-preview"))
    let entries = (0..<6).map { FolderEntry(url: root.url.appendingPathComponent("\($0).png"), root: root) }
    let ids = entries.map(\.itemID)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    session.focus(ids[0])
    let single = ImageContextMenu(clickedItemID: ids[3], selection: session.selection, entries: entries)
    session.focus(ids[5])
    session.preview(single, availableItemIDs: ids)
    #expect(session.previewSet?.itemIDs == ids)
    #expect(session.previewSet?.currentItemID == ids[3])

    session.beginBrowsing(items: ids, sourceVersion: .init(2), scrollAnchor: ids[0])
    session.select(ids[1])
    session.select(ids[2], modifier: .command)
    session.select(ids[4], modifier: .command)
    let multi = ImageContextMenu(clickedItemID: ids[2], selection: session.selection, entries: entries)
    session.select(ids[0])
    session.preview(multi, availableItemIDs: ids)
    #expect(session.previewSet?.itemIDs == [ids[1], ids[2], ids[4]])
    #expect(session.previewSet?.currentItemID == ids[4])
}

@Test @MainActor func imageContextMenuLockBlocksGridCommandsUntilMenuCloses() {
    let session = ViewerSession()
    session.beginBrowsing(items: sessionItems(2), sourceVersion: .init(1), scrollAnchor: nil)
    session.setImageContextMenuOpen(true)
    #expect(session.isMenuTracking)
    #expect(!CommandRouter().route(.preview, from: .key, to: session))
    session.setImageContextMenuOpen(false)
    #expect(!session.isMenuTracking)
    #expect(CommandRouter().route(.preview, from: .key, to: session))
}

@Test @MainActor func imageContextMenuPreviewDropsDeletedClickedItemButKeepsSelectionSurvivors() {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/i144-preview-deleted"))
    let entries = (0..<4).map { FolderEntry(url: root.url.appendingPathComponent("\($0).png"), root: root) }
    let ids = entries.map(\.itemID)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    session.select(ids[1]); session.select(ids[2], modifier: .command)
    let menu = ImageContextMenu(clickedItemID: ids[2], selection: session.selection, entries: entries)
    session.updateItems([ids[0], ids[1], ids[3]], sourceVersion: .init(2))
    session.preview(menu)
    #expect(session.previewSet?.itemIDs == [ids[1]])
    #expect(session.previewSet?.currentItemID == ids[1])
}

@Test @MainActor func imageContextMenuPreviewUsesOnlyDiskSurvivorsFromCapturedRange() {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/i144-preview-disk"))
    let entries = (0..<4).map { FolderEntry(url: root.url.appendingPathComponent("\($0).png"), root: root) }
    let ids = entries.map(\.itemID)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    session.select(ids[1]); session.select(ids[2], modifier: .command)
    let menu = ImageContextMenu(clickedItemID: ids[2], selection: session.selection, entries: entries)
    session.preview(menu, availableItemIDs: [ids[1]])
    #expect(session.previewSet?.itemIDs == [ids[1]])
    #expect(session.previewSet?.currentItemID == ids[1])
}
