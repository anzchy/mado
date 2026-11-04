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
    private let isSelectionPreview: Bool
    private var followsCurrentOnReturn = false
    public init(items: [ItemID], sourceVersion: PreviewSourceVersion, origin: PreviewOrigin) {
        self.sourceVersion = sourceVersion
        self.origin = origin
        isSelectionPreview = origin.selection.selectedItemIDs.count > 1
        itemIDs = isSelectionPreview
            ? items.filter { origin.selection.selectedItemIDs.contains($0) } : items
        currentItemID = origin.selection.currentItemID.flatMap { itemIDs.contains($0) ? $0 : nil } ?? itemIDs.first
    }
    public mutating func move(forward: Bool, mayWrap: Bool = false) {
        guard let currentItemID, let index = itemIDs.firstIndex(of: currentItemID) else { return }
        let next = index + (forward ? 1 : -1)
        if itemIDs.indices.contains(next) {
            self.currentItemID = itemIDs[next]
            if !isSelectionPreview { followsCurrentOnReturn = true }
        }
        else if mayWrap, itemIDs.count > 1 {
            self.currentItemID = forward ? itemIDs.first : itemIDs.last
            followsCurrentOnReturn = true
        }
        // Folder paging returns to the last viewed item; a selection preview keeps its origin until a wrap.
        // A preview with no successful page retains its original scroll position. Focus preserves picked IDs and anchor.
        if followsCurrentOnReturn, let current = self.currentItemID {
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
        if followsCurrentOnReturn, let currentItemID {
            origin.selection.focus(currentItemID, in: itemIDs)
            origin.scrollAnchor = currentItemID
        }
    }
}
