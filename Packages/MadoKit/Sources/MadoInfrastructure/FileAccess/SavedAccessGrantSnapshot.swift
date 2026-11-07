import Foundation
import MadoCore

/// An actor-consistent saved-record version, not authorization to read files.
/// Admission only fences a short synchronous state update against grant replacement.
public struct SavedAccessGrantSnapshot: Sendable {
    public let record: AccessRootRecord
    public let bookmarkVolume: AccessProbeVolume
    public let rootURL: URL?
    private let version: AccessWorkPermit
    init(record: AccessRootRecord, bookmarkVolume: AccessProbeVolume, rootURL: URL?, version: AccessWorkPermit) {
        self.record = record; self.bookmarkVolume = bookmarkVolume; self.rootURL = rootURL
        self.version = version
    }
    public func admitting<T>(_ operation: () throws -> T) throws -> T {
        try AccessWorkPermit.admitting(version, operation)
    }
}
