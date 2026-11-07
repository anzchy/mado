import Foundation
import MadoCore

/// Identity recorded during readable browsing, never first established after loss.
/// This is a location reference, not file-read authorization.
public struct AccessFolderRecoveryReference: Sendable {
    public let rootID: AccessRootID
    public let relativeComponents: [String]
    /// The canonical pre-loss location; a hint for associating a window, never authority.
    public let folderURL: URL
    public let rootIdentity: FileResourceIdentity
    public let folderIdentity: FileResourceIdentity
    init(rootID: AccessRootID, relativeComponents: [String], folderURL: URL, rootIdentity: FileResourceIdentity,
         folderIdentity: FileResourceIdentity) {
        self.rootID = rootID; self.relativeComponents = relativeComponents
        self.folderURL = folderURL
        self.rootIdentity = rootIdentity; self.folderIdentity = folderIdentity
    }
}

/// A scoped, listed location plus the saved-record version for final admission.
public struct AccessFolderRecoveryLocation: Sendable {
    public let rootURL: URL
    public let folderURL: URL
    public let grant: SavedAccessGrantSnapshot
    init(rootURL: URL, folderURL: URL, grant: SavedAccessGrantSnapshot) {
        self.rootURL = rootURL; self.folderURL = folderURL; self.grant = grant
    }
}
