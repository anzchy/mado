import MadoCore

/// A window-owned, transient filename filter over the scanner's current projection.
@MainActor public final class GridSearchState {
    public private(set) var term = ""
    public private(set) var preferredCurrentItemID: ItemID?
    private var chosenCurrentItemID: ItemID?
    public init() {}
    public func setTerm(_ value: String, currentItemID: ItemID?) {
        if term.isEmpty && !value.isEmpty { preferredCurrentItemID = currentItemID; chosenCurrentItemID = nil }
        term = value
    }
    public func clear() { term = "" }
    public func userChoseCurrentItem(_ id: ItemID) { if !term.isEmpty { chosenCurrentItemID = id } }
    public func reset() { term = ""; preferredCurrentItemID = nil; chosenCurrentItemID = nil }
    public func project(_ snapshot: FolderSnapshot) -> FolderSnapshot { snapshot.filteringFilename(term) }
    public func currentItemID(in snapshot: FolderSnapshot, currentItemID: ItemID?) -> ItemID? {
        if term.isEmpty {
            let chosen = chosenCurrentItemID
            chosenCurrentItemID = nil
            if let chosen, snapshot.navigationIndex(for: chosen) != nil {
                preferredCurrentItemID = nil
                return chosen
            }
        }
        if term.isEmpty, let preferredCurrentItemID {
            self.preferredCurrentItemID = nil
            if snapshot.navigationIndex(for: preferredCurrentItemID) != nil { return preferredCurrentItemID }
        }
        if let currentItemID, snapshot.navigationIndex(for: currentItemID) != nil { return currentItemID }
        return snapshot.navigationEntries.first?.itemID
    }
}
