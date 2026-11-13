import Foundation
import Testing
import MadoCore
import MadoApplication

@Test func imageContextMenuKeepsCapturedTargetsAndSubtractsUnavailableEntries() {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/i144"))
    let entries = (1...5).map { number in
        FolderEntry(url: root.url.appendingPathComponent("\(number).png"), root: root)
    }
    let ids = entries.map(\.itemID)
    var selection = BrowserSelection()
    selection.click(ids[1], in: ids)
    selection.click(ids[2], modifier: .command, in: ids)
    selection.click(ids[4], modifier: .command, in: ids)

    let outside = ImageContextMenu(clickedItemID: ids[3], selection: selection, entries: entries)
    let inside = ImageContextMenu(clickedItemID: ids[2], selection: selection, entries: entries)
    selection.click(ids[0], in: ids)
    #expect(outside.resolvedEntries(in: entries, rootReadable: true, fileExists: { _ in true }).map(\.itemID) == [ids[3]])
    #expect(inside.resolvedEntries(in: entries, rootReadable: true, fileExists: { _ in true }).map(\.itemID) == [ids[1], ids[2], ids[4]])
    #expect(inside.resolvedEntries(in: [entries[0], entries[1], entries[4]], rootReadable: true,
                                   fileExists: { _ in true }).map(\.itemID) == [ids[1], ids[4]])
    #expect(outside.resolvedEntries(in: entries, rootReadable: false, fileExists: { _ in true }).isEmpty)
    #expect(outside.resolvedEntries(in: entries, rootReadable: true, fileExists: { _ in false }).isEmpty)
}
