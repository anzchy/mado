import Foundation

/// Load failures carry available identity; access failures remain the FileAccess port's errors.
public struct ImageLoadError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case unsupportedFormat, corruptImage, resourceLimit, sourceChanged, cancelled
    }
    public let kind: Kind
    public let itemID: ItemID?
    public let revision: FileRevision?
    public init(_ kind: Kind, itemID: ItemID? = nil, revision: FileRevision? = nil) {
        self.kind = kind; self.itemID = itemID; self.revision = revision
    }
}
