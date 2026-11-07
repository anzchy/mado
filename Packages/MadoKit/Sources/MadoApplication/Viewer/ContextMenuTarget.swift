import MadoCore

/// Captured when opening the menu; later selection changes cannot retarget it.
public struct ContextMenuTarget: Sendable {
    public let itemIDs: [ItemID]
    public init(clickedItemID: ItemID, selection: BrowserSelection, items: [ItemID]) {
        if selection.selectedItemIDs.count > 1, selection.selectedItemIDs.contains(clickedItemID) {
            itemIDs = items.filter { selection.selectedItemIDs.contains($0) }
        } else {
            itemIDs = items.contains(clickedItemID) ? [clickedItemID] : []
        }
    }
    public func resolve(availableItemIDs: [ItemID]) -> [ItemID] {
        let available = Set(availableItemIDs)
        return itemIDs.filter { available.contains($0) }
    }
}
