import Foundation

/// Identity scope supplied by an authorized caller; it does not confer access or own a lease.
public struct ItemIdentityRoot: Sendable {
    public let id: AccessRootID
    public let url: URL
    public init(id: AccessRootID, url: URL) { self.id = id; self.url = url }
}

public protocol ItemIdentityResolving: Sendable {
    func identity(for fileURL: URL) async throws -> ItemID
}
