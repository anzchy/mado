import Foundation
import MadoCore

/// Captured identities for a grid image menu. Availability is checked when validating and invoking.
public struct ImageContextMenu: Sendable {
    public let clickedItemID: ItemID
    public let target: ContextMenuTarget
    public let openingItemIDs: [ItemID]
    public let openingSelection: BrowserSelection
    public var isEmpty: Bool { target.itemIDs.isEmpty }
    public init(clickedItemID: ItemID, selection: BrowserSelection, entries: [FolderEntry]) {
        let ids = entries.map(\.itemID)
        self.clickedItemID = clickedItemID
        self.openingItemIDs = ids
        self.openingSelection = selection
        self.target = ContextMenuTarget(clickedItemID: clickedItemID, selection: selection,
                                        items: ids)
    }
    public func resolvedEntries(in entries: [FolderEntry], rootReadable: Bool,
                                fileExists: (URL) -> Bool) -> [FolderEntry] {
        guard rootReadable else { return [] }
        let byID = Dictionary(entries.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return target.itemIDs.compactMap { id in
            guard let entry = byID[id], fileExists(entry.url) else { return nil }
            return entry
        }
    }
}
