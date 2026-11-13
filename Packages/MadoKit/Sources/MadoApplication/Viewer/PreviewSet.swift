import MadoCore

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
    /// A context menu may preview a captured range while Esc restores a different grid selection.
    init(items: [ItemID], sourceVersion: PreviewSourceVersion, origin: PreviewOrigin,
         startingAt start: ItemID?, selectionPreview: Bool) {
        self.sourceVersion = sourceVersion
        self.origin = origin
        isSelectionPreview = selectionPreview
        itemIDs = items
        if let start, items.contains(start) { currentItemID = start }
        else { currentItemID = items.first }
    }
    public mutating func move(forward: Bool, mayWrap: Bool = false) {
        guard let currentItemID, let index = itemIDs.firstIndex(of: currentItemID) else { return }
        let next = index + (forward ? 1 : -1)
        if itemIDs.indices.contains(next) {
            self.currentItemID = itemIDs[next]
            followsCurrentOnReturn = true
        }
        else if mayWrap, itemIDs.count > 1 {
            self.currentItemID = forward ? itemIDs.first : itemIDs.last
            followsCurrentOnReturn = true
        }
        updateReturnOrigin()
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
        updateReturnOrigin()
    }
    private mutating func updateReturnOrigin() {
        // No successful page keeps the entry viewport. After paging, single picks transfer
        // to the last viewed image; selection previews keep their surviving picks and anchor.
        guard followsCurrentOnReturn, let currentItemID else { return }
        if isSelectionPreview { origin.selection.focus(currentItemID, in: itemIDs) }
        else { origin.selection.click(currentItemID, in: itemIDs) }
        origin.scrollAnchor = currentItemID
    }
}
