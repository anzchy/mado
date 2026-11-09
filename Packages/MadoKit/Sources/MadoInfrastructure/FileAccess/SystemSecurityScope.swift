import Foundation
import MadoCore

/// One native creation boundary shared by session grants and the access probe.
struct SecurityScopedBookmarkCreation: Sendable {
    private let bookmarkData: @Sendable (URL, URL.BookmarkCreationOptions, Set<URLResourceKey>?) throws -> Data

    init(bookmarkData: @escaping @Sendable (URL, URL.BookmarkCreationOptions, Set<URLResourceKey>?) throws -> Data = {
        try $0.bookmarkData(options: $1, includingResourceValuesForKeys: $2, relativeTo: nil)
    }) {
        self.bookmarkData = bookmarkData
    }

    func create(for url: URL, keys: Set<URLResourceKey>?) throws -> Data {
        try bookmarkData(url, [.withSecurityScope, .securityScopeAllowOnlyReadAccess], keys)
    }
}

public struct SystemSecurityScope: SecurityScope, BookmarkCoding {
    private let bookmarkCreation: SecurityScopedBookmarkCreation
    public init() { bookmarkCreation = SecurityScopedBookmarkCreation() }
    init(bookmarkCreation: SecurityScopedBookmarkCreation) { self.bookmarkCreation = bookmarkCreation }
    public var requiresEmbeddedIdentity: Bool { true }
    public func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    public func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    public func create(for url: URL) throws -> Data {
        try bookmarkCreation.create(for: url, keys: [.volumeUUIDStringKey, .volumeNameKey,
                                                   .volumeURLKey, .fileResourceIdentifierKey])
    }
    public func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutMounting, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, stale: stale)
    }
}
