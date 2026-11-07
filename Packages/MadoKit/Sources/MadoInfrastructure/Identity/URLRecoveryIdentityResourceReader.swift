import Foundation

/// Session-only recovery evidence. Never persist an inode as a durable identity.
public struct URLRecoveryIdentityResourceReader: FileIdentityResourceReading {
    public init() {}
    public func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        var fresh = fileURL
        fresh.removeAllCachedResourceValues()
        return Self.identity(from: try fresh.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey]))
    }
    static func identity(from values: URLResourceValues) -> FileResourceIdentity? {
        guard let volume = values.volumeUUIDString,
              let inode = values.allValues[.fileIdentifierKey] as? NSNumber else { return nil }
        // NSNumber preserves the full unsigned inode; opaque resource tokens may
        // additionally encode mount-specific device identity. Neither is persisted here.
        return FileResourceIdentity(volumeUUID: volume, fileIdentifier: "inode:\(inode.uint64Value)")
    }
    static func token(from values: URLResourceValues) -> String? {
        identity(from: values).map { "\($0.volumeUUID):\($0.fileIdentifier)" }
    }
}
