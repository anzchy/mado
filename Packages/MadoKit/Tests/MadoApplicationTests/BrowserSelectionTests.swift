import Foundation
import Testing
import MadoCore
import MadoApplication

func sessionItems(_ count: Int = 5) -> [ItemID] {
    (0..<count).map { _ in ItemID.ephemeral(UUID()) }
}

@Test func browserSelectionModifiersAndReconciliation() {
    let ids = sessionItems()
    var selection = BrowserSelection()
    #expect(selection.selectedItemIDs.isEmpty)
    #expect(selection.currentItemID == nil)
    #expect(selection.anchorItemID == nil)
    selection.click(ids[1], in: ids)
    #expect(selection.selectedItemIDs == [ids[1]])
    #expect(selection.currentItemID == ids[1])
    #expect(selection.anchorItemID == ids[1])
    selection.click(ids[3], modifier: .shift, in: ids)
    #expect(selection.selectedItemIDs == Set([ids[1], ids[2], ids[3]]))
    #expect(selection.currentItemID == ids[3])
    #expect(selection.anchorItemID == ids[1])
    selection.click(ids[0], modifier: .shift, in: ids)
    #expect(selection.selectedItemIDs == Set([ids[0], ids[1]]))
    #expect(selection.currentItemID == ids[0])
    #expect(selection.anchorItemID == ids[1])
    selection.click(ids[0], modifier: .command, in: ids)
    #expect(selection.selectedItemIDs == [ids[1]])
    #expect(selection.currentItemID == ids[0])
    #expect(selection.anchorItemID == ids[0])
    selection.click(ids[4], modifier: .command, in: ids)
    #expect(selection.selectedItemIDs == Set([ids[1], ids[4]]))
    #expect(selection.currentItemID == ids[4])
    #expect(selection.anchorItemID == ids[4])
    let before = selection
    for modifier: SelectionModifier in [.plain, .command, .shift] {
        selection.click(sessionItems(1)[0], modifier: modifier, in: ids)
        #expect(selection == before)
    }
    selection.reconcile(with: [ids[1]])
    #expect(selection.selectedItemIDs == [ids[1]])
    #expect(selection.currentItemID == nil)
    #expect(selection.anchorItemID == nil)
    selection.click(ids[3], modifier: .shift, in: ids)
    #expect(selection.selectedItemIDs == [ids[3]])
    #expect(selection.anchorItemID == ids[3])
    selection.click(ids[0], modifier: .shift, in: [ids[0], ids[1]])
    #expect(selection.selectedItemIDs == [ids[0]])
    #expect(selection.currentItemID == ids[0])
    #expect(selection.anchorItemID == ids[0])
    selection.reconcile(with: ids)
    #expect(selection.selectedItemIDs == [ids[0]])
    #expect(selection.currentItemID == ids[0])
    #expect(selection.anchorItemID == ids[0])
    selection.reconcile(with: [])
    #expect(selection == BrowserSelection())
}
