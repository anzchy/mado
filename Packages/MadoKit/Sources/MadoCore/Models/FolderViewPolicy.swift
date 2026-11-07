import Foundation

public enum FolderSortKey: String, CaseIterable, Codable, Sendable {
    case name, modificationDate, type, size, captureDate, pixelDimensions
}

public struct FolderImageMetadata: Equatable, Sendable {
    public let captureDate: Date?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public init(captureDate: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.captureDate = captureDate; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

public enum FolderSortDirection: String, CaseIterable, Codable, Sendable {
    case ascending, descending
}

public struct FolderViewConditions: Equatable, Sendable {
    public static func canonicalExtension(_ value: String) -> String {
        let lower = value.lowercased()
        return lower == "jpeg" ? "jpg" : lower
    }
    public var sort: FolderSortKey
    public var direction: FolderSortDirection
    public var selectedExtensions: Set<String>?

    public init(sort: FolderSortKey = .name, direction: FolderSortDirection = .ascending,
                selectedExtensions: Set<String>? = nil) {
        self.sort = sort
        self.direction = direction
        self.selectedExtensions = selectedExtensions.map { Set($0.map(Self.canonicalExtension)) }
    }

    public func includesExtension(_ value: String) -> Bool {
        guard let selectedExtensions else { return true }
        let candidate = Self.canonicalExtension(value)
        return selectedExtensions.contains { Self.canonicalExtension($0) == candidate }
    }
}

extension FolderSnapshot {
    public func applying(_ conditions: FolderViewConditions, metadata: [ItemID: FolderImageMetadata] = [:]) -> Self {
        let selected = conditions.selectedExtensions.map { Set($0.map(FolderViewConditions.canonicalExtension)) }
        let projected = entries.filter { selected?.contains(FolderViewConditions.canonicalExtension($0.normalizedExtension)) != false }
            .sorted { folderEntryBefore($0, $1, conditions: conditions, metadata: metadata) }
        return Self(version: version, orderedEntries: projected, isComplete: isComplete)
    }
}

private func folderEntryBefore(_ lhs: FolderEntry, _ rhs: FolderEntry,
                               conditions: FolderViewConditions, metadata: [ItemID: FolderImageMetadata]) -> Bool {
    let comparison: ComparisonResult
    switch conditions.sort {
    case .name:
        comparison = folderNaturalNameCompare(lhs, rhs)
    case .type:
        comparison = lhs.normalizedExtension.compare(rhs.normalizedExtension)
    case .modificationDate:
        switch (lhs.modificationDate, rhs.modificationDate) {
        case (nil, nil): comparison = .orderedSame
        case (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): comparison = left.compare(right)
        }
    case .size:
        switch (lhs.fileSize, rhs.fileSize) {
        case (nil, nil): comparison = .orderedSame
        case (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?):
            comparison = left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
        }
    case .captureDate:
        switch (metadata[lhs.itemID]?.captureDate, metadata[rhs.itemID]?.captureDate) {
        case (nil, nil): comparison = .orderedSame
        case (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): comparison = left.compare(right)
        }
    case .pixelDimensions:
        func dimensions(_ entry: FolderEntry) -> (Int, Int)? {
            guard let value = metadata[entry.itemID], let width = value.pixelWidth,
                  let height = value.pixelHeight, width > 0, height > 0 else { return nil }
            return (width, height)
        }
        switch (dimensions(lhs), dimensions(rhs)) {
        case (nil, nil): comparison = .orderedSame
        case (nil, _?): return false
        case (_?, nil): return true
        case let ((leftWidth, leftHeight)?, (rightWidth, rightHeight)?):
            let leftArea = UInt(leftWidth).multipliedFullWidth(by: UInt(leftHeight))
            let rightArea = UInt(rightWidth).multipliedFullWidth(by: UInt(rightHeight))
            if leftArea.high != rightArea.high {
                comparison = leftArea.high < rightArea.high ? .orderedAscending : .orderedDescending
            } else if leftArea.low != rightArea.low {
                comparison = leftArea.low < rightArea.low ? .orderedAscending : .orderedDescending
            } else if leftWidth != rightWidth || leftHeight != rightHeight {
                return [leftWidth, leftHeight].lexicographicallyPrecedes([rightWidth, rightHeight])
            } else { comparison = .orderedSame }
        }
    }
    guard comparison == .orderedSame else {
        return conditions.direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
    let names = folderNaturalNameCompare(lhs, rhs)
    if names != .orderedSame { return names == .orderedAscending }
    if lhs.itemID != rhs.itemID { return lhs.itemID.stableEncoding < rhs.itemID.stableEncoding }
    return lhs.relativePath < rhs.relativePath
}

func folderNaturalNameCompare(_ lhs: FolderEntry, _ rhs: FolderEntry) -> ComparisonResult {
    lhs.url.lastPathComponent.lowercased().localizedStandardCompare(rhs.url.lastPathComponent.lowercased())
}
