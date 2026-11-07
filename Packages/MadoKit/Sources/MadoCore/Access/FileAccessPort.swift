import Foundation

public enum FileAccessError: Error, Equatable, Sendable {
    case needsReconnection(AccessRootID), needsFileReconnection(URL), fileDeleted(URL), outsideRoot, startFailed, corruptStore, invalidFolder
    case alreadyGranted(AccessRootID)
}

public enum AccessRequest: Hashable, Sendable {
    case root(AccessRootID, file: URL)
    case fileGrant(URL)
}

public struct AccessLease: Hashable, Sendable {
    public let token: UUID
    public let url: URL
    public let rootID: AccessRootID?
    /// Set only when a File Grant's bookmark resolved to a new file URL.
    public let resolvedFileURL: URL?
    public init(token: UUID = UUID(), url: URL, rootID: AccessRootID?, resolvedFileURL: URL? = nil) {
        self.token = token; self.url = url; self.rootID = rootID; self.resolvedFileURL = resolvedFileURL
    }
}

public protocol SecurityScope: Sendable {
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
    /// A point-in-time check of access already permitted by the sandbox.
    func isReadable(_ url: URL) -> Bool
}

public protocol AccessLeasing: Sendable {
    func acquire(_ request: AccessRequest) async throws -> AccessLease
    func release(_ lease: AccessLease) async
    /// Rebase a previously authorized folder after its Access Root bookmark moved.
    func relocatedFolder(_ folder: URL, rootID: AccessRootID) async throws -> URL?
}

extension AccessLeasing {
    public func relocatedFolder(_ folder: URL, rootID: AccessRootID) async throws -> URL? { nil }
    public func withLease<T: Sendable>(_ request: AccessRequest,
        operation: @Sendable (AccessLease) async throws -> T) async throws -> T {
        let lease = try await acquire(request)
        do {
            try Task.checkCancellation()
            let result = try await operation(lease)
            await release(lease)
            return result
        } catch {
            await release(lease)
            throw error
        }
    }
}

public struct ResolvedBookmark: Sendable {
    public let url: URL
    public let stale: Bool
    public init(url: URL, stale: Bool) { self.url = url; self.stale = stale }
}
public protocol BookmarkCoding: Sendable {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedBookmark
    /// True when created bookmarks embed the volume UUID and root resource identity,
    /// so a root on a UUID-bearing volume is trusted only after matching them.
    var requiresEmbeddedIdentity: Bool { get }
}
public extension BookmarkCoding {
    var requiresEmbeddedIdentity: Bool { false }
}

public struct AccessRootRecord: Codable, Equatable, Sendable {
    public let id: AccessRootID
    public var bookmark: Data
    public let displayName: String
    public let creatingBuildSHA: String
    public let createdAt: Date
    public init(id: AccessRootID, bookmark: Data, displayName: String, creatingBuildSHA: String, createdAt: Date) {
        self.id = id; self.bookmark = bookmark; self.displayName = displayName
        self.creatingBuildSHA = creatingBuildSHA; self.createdAt = createdAt
    }
}
