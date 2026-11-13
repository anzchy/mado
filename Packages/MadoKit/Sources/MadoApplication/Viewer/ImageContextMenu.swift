import Foundation
import MadoCore

/// Captured identities for a grid image menu. Availability is checked when validating and invoking.
public struct ImageContextMenu: Sendable {
    public let clickedItemID: ItemID
    public let target: ContextMenuTarget
    public init(clickedItemID: ItemID, selection: BrowserSelection, entries: [FolderEntry]) {
        self.clickedItemID = clickedItemID
        self.target = ContextMenuTarget(clickedItemID: clickedItemID, selection: selection,
                                        items: entries.map(\.itemID))
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
