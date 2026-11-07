import Foundation
import MadoCore

public struct SystemSecurityScope: SecurityScope, BookmarkCoding {
    public init() {}
    public var requiresEmbeddedIdentity: Bool { true }
    public func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    public func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    public func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey,
                                                               .volumeURLKey, .fileResourceIdentifierKey], relativeTo: nil)
    }
    public func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutMounting, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, stale: stale)
    }
}
