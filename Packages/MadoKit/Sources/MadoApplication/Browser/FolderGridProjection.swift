import Foundation
import MadoCore

/// Main-actor browse state projected from the authorized folder scanner.
@MainActor public final class FolderGridProjection {
    public private(set) var snapshot: FolderSnapshot?
    public private(set) var selectedItemID: ItemID?
    public private(set) var scrollAnchor: ItemID?
    public init() {}
    @discardableResult public func apply(_ value: FolderSnapshot) -> Bool {
        if let previous = snapshot {
            if previous.version.rootID == value.version.rootID,
               previous.version.folder == value.version.folder {
                // A rescan's partial snapshots never replace a complete grid; only its completion does.
                guard value.version.generation >= previous.version.generation,
                      value.isComplete || !previous.isComplete else { return false }
            } else {
                selectedItemID = nil
                scrollAnchor = nil
            }
        }
        snapshot = value
        let available = Set(value.navigationEntries.map(\.itemID))
        if let selectedItemID, !available.contains(selectedItemID) { self.selectedItemID = nil }
        if let scrollAnchor, !available.contains(scrollAnchor) { self.scrollAnchor = nil }
        return true
    }
    public func select(_ id: ItemID) {
        guard entry(for: id) != nil else { return }
        selectedItemID = id
    }
    public func setScrollAnchor(_ id: ItemID?) {
        scrollAnchor = id.flatMap { entry(for: $0) != nil ? $0 : nil }
    }
    public func entry(for id: ItemID) -> FolderEntry? {
        guard let snapshot, let index = snapshot.navigationIndex(for: id) else { return nil }
        return snapshot.navigationEntries[index]
    }
}
