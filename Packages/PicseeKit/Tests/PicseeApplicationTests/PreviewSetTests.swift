import Testing
import PicseeApplication

@Test func previewSetFrozenOrderRemovalAndOrigin() {
    let ids = sessionItems()
    var selection = BrowserSelection()
    selection.click(ids[2], in: ids)
    let origin = PreviewOrigin(selection: selection, scrollAnchor: ids[1])
    var preview = PreviewSet(items: ids, sourceVersion: .init(7), origin: origin)
    #expect(preview.sourceVersion.rawValue == 7)
    #expect(preview.itemIDs == ids)
    #expect(preview.currentItemID == ids[2])
    #expect(preview.origin == origin)
    preview.move(forward: true)
    #expect(preview.currentItemID == ids[3])
    preview.move(forward: true)
    preview.move(forward: true)
    #expect(preview.currentItemID == ids[4])
    for _ in 0..<6 { preview.move(forward: false) }
    #expect(preview.currentItemID == ids[0])
    preview.reconcile(availableItemIDs: ids.reversed() + sessionItems(1))
    #expect(preview.itemIDs == ids)
    preview.reconcile(availableItemIDs: Array(ids[1...]))
    #expect(preview.currentItemID == ids[1])
    preview.move(forward: true)
    #expect(preview.currentItemID == ids[2])
    preview.reconcile(availableItemIDs: [ids[1]])
    #expect(preview.currentItemID == ids[1])
    // #492 / owner #345: after paging, a removed current follows the surviving viewed successor.
    #expect(preview.origin.selection.currentItemID == ids[1])
    #expect(preview.origin.selection.selectedItemIDs.isEmpty)
    #expect(preview.origin.scrollAnchor == ids[1])
    preview.reconcile(availableItemIDs: [])
    #expect(preview.currentItemID == nil)
    #expect(preview.origin.scrollAnchor == nil)
    preview.move(forward: true)
    #expect(preview.itemIDs.isEmpty)

    selection.click(ids[4], modifier: .command, in: ids)
    var multi = PreviewSet(items: ids, sourceVersion: .init(8),
                           origin: .init(selection: selection, scrollAnchor: nil))
    #expect(multi.itemIDs == [ids[2], ids[4]])
    #expect(multi.currentItemID == ids[4])
    multi.reconcile(availableItemIDs: ids + sessionItems(1))
    #expect(multi.itemIDs == [ids[2], ids[4]])
    selection.click(ids[0], modifier: .command, in: ids)
    selection.click(ids[0], modifier: .command, in: ids)
    let outside = PreviewSet(items: ids, sourceVersion: .init(9),
                             origin: .init(selection: selection, scrollAnchor: nil))
    #expect(outside.currentItemID == ids[2])
    let zero = PreviewSet(items: ids, sourceVersion: .init(0),
                          origin: .init(selection: BrowserSelection(), scrollAnchor: nil))
    #expect(zero.itemIDs == ids)
    #expect(zero.currentItemID == ids[0])
    let empty = PreviewSet(items: [], sourceVersion: .init(0),
                           origin: .init(selection: BrowserSelection(), scrollAnchor: nil))
    #expect(empty.currentItemID == nil)
}
