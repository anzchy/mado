import Foundation
import MadoCore

/// Opens a descriptor for a File Grant while its security scope is held.
public enum FileGrantWatchDescriptor {
    public static func open(grant: URL, access: any AccessLeasing,
        opener: @escaping @Sendable (URL) -> Int32) async throws -> Int32 {
        try await access.withLease(.fileGrant(grant)) { lease in
            opener(lease.url)
        }
    }
}

@MainActor public final class FileGrantWatchFallback {
    public private(set) var foregroundOnly: Set<URL> = []
    public init() {}
    /// Whether this failure should be logged for the grant.
    public func recordFailure(_ grant: URL) -> Bool {
        foregroundOnly.insert(grant.standardizedFileURL).inserted
    }
}
