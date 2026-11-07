import Testing
import MadoApplication

@Test func contextMenuTargetRemainsBoundToOriginalIdentities() {
    let ids = sessionItems()
    var selection = BrowserSelection()
    selection.click(ids[3], in: ids)
    selection.click(ids[1], modifier: .command, in: ids)
    let multi = ContextMenuTarget(clickedItemID: ids[3], selection: selection, items: ids)
    #expect(multi.itemIDs == [ids[1], ids[3]])
    let outside = ContextMenuTarget(clickedItemID: ids[4], selection: selection, items: ids)
    #expect(outside.itemIDs == [ids[4]])
    selection.click(ids[0], in: ids)
    let single = ContextMenuTarget(clickedItemID: ids[0], selection: selection, items: ids)
    #expect(single.itemIDs == [ids[0]])
    selection.click(ids[2], in: ids)
    #expect(multi.resolve(availableItemIDs: ids.reversed()) == [ids[1], ids[3]])
    #expect(outside.resolve(availableItemIDs: ids) == [ids[4]])
    #expect(single.resolve(availableItemIDs: ids) == [ids[0]])
    #expect(multi.resolve(availableItemIDs: [ids[0], ids[3]]) == [ids[3]])
    #expect(outside.resolve(availableItemIDs: [ids[0], ids[3]]).isEmpty)
    #expect(ContextMenuTarget(clickedItemID: sessionItems(1)[0], selection: selection, items: ids).itemIDs.isEmpty)
}
