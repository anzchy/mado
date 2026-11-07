import Foundation

/// A reference only: no bookmark or authority is stored here.
public struct RecentFolder: Codable, Equatable, Sendable {
    public let rootID: AccessRootID
    public let url: URL
    public let displayName: String
    public let openedAt: Date
    /// Root location when this reference was recorded; optional for legacy stores.
    /// This identifies its relative suffix and confers no access authority.
    public let recordedRoot: URL?
    public init(rootID: AccessRootID, url: URL, displayName: String, openedAt: Date = Date(), recordedRoot: URL? = nil) {
        self.rootID = rootID; self.url = url; self.displayName = displayName; self.openedAt = openedAt
        self.recordedRoot = recordedRoot
    }
}
