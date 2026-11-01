import PicseeCore

/// Local source token until the folder snapshot API arrives; not a file revision.
public struct PreviewSourceVersion: Equatable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

public struct PreviewOrigin: Equatable, Sendable {
    public var selection: BrowserSelection
    public var scrollAnchor: ItemID?
    public init(selection: BrowserSelection, scrollAnchor: ItemID?) {
        self.selection = selection
        self.scrollAnchor = scrollAnchor
    }
}

/// Frozen membership/order. Reconciliation can only shrink it.
public struct PreviewSet: Equatable, Sendable {
    public let sourceVersion: PreviewSourceVersion
    public private(set) var itemIDs: [ItemID] = []
    public private(set) var currentItemID: ItemID?
    public private(set) var origin: PreviewOrigin
    private var hasWrapped = false
    public init(items: [ItemID], sourceVersion: PreviewSourceVersion, origin: PreviewOrigin) {
        self.sourceVersion = sourceVersion
        self.origin = origin
        itemIDs = origin.selection.selectedItemIDs.count > 1
            ? items.filter { origin.selection.selectedItemIDs.contains($0) } : items
        currentItemID = origin.selection.currentItemID.flatMap { itemIDs.contains($0) ? $0 : nil } ?? itemIDs.first
    }
    public mutating func move(forward: Bool, mayWrap: Bool = false) {
        guard let currentItemID, let index = itemIDs.firstIndex(of: currentItemID) else { return }
        let next = index + (forward ? 1 : -1)
        if itemIDs.indices.contains(next) { self.currentItemID = itemIDs[next] }
        else if mayWrap, itemIDs.count > 1 {
            self.currentItemID = forward ? itemIDs.first : itemIDs.last
            hasWrapped = true
        }
        // Once a wrap changes the return destination, later paging keeps it at the latest viewed item.
        // Focus preserves the original picked set and selection anchor.
        if hasWrapped, let current = self.currentItemID {
            origin.selection.focus(current, in: itemIDs)
            origin.scrollAnchor = current
        }
    }
    public mutating func reconcile(availableItemIDs: [ItemID]) {
        let available = Set(availableItemIDs)
        if let currentItemID, !available.contains(currentItemID), let index = itemIDs.firstIndex(of: currentItemID) {
            self.currentItemID = itemIDs.dropFirst(index + 1).first(where: { available.contains($0) })
                ?? itemIDs.prefix(index).last(where: { available.contains($0) })
        }
        itemIDs.removeAll { !available.contains($0) }
        origin.selection.reconcile(with: availableItemIDs)
        if let anchor = origin.scrollAnchor, !available.contains(anchor) { origin.scrollAnchor = nil }
        if hasWrapped, let currentItemID {
            origin.selection.focus(currentItemID, in: itemIDs)
            origin.scrollAnchor = currentItemID
        }
    }
}
