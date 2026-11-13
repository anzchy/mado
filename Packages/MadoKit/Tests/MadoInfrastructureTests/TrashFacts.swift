import Foundation
import MadoCore
@testable import MadoInfrastructure

/// #672 (DECISION-TRASH-TESTS on #650): Trash facts for the default package lane.
/// The default lane never calls DesktopServices or `FileManager.trashItem`; the real
/// operation compiles only with `-DMADO_TRASH_INTEGRATION` and runs in the serialized
/// integration lane (`node scripts/tdd/trash-lane.mjs`).
enum TrashFacts {
    /// A location under the real user Trash path. `FileAccess.isTrashed` is path based,
    /// so this location never has to exist.
    static func syntheticTrashURL(_ name: String) throws -> URL {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return trash.appendingPathComponent("mado-672-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    struct Moved {
        let url: URL
        let cleanup: () -> Void
    }

    /// Puts `url` in the user Trash. The default lane renames it into a fresh folder there with
    /// plain file-system calls (same volume, so the inode and its bookmarks follow), which is
    /// what `FileAccess.isTrashed` and bookmark resolution observe. `real` asks DesktopServices
    /// and exists only in the Trash lane.
    static func trash(_ url: URL, real: Bool) throws -> Moved {
        #if MADO_TRASH_INTEGRATION
        if real {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            guard let item = trashed as URL? else { throw CocoaError(.fileNoSuchFile) }
            return Moved(url: item) { try? FileManager.default.removeItem(at: item) }
        }
        #endif
        precondition(!real, "the real-Trash case compiles only with MADO_TRASH_INTEGRATION")
        let destination = try syntheticTrashURL(url.lastPathComponent)
        let container = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: url, to: destination)
        return Moved(url: destination) { try? FileManager.default.removeItem(at: container) }
    }
}

/// Real bookmark data whose resolution can be redirected to where the item "went".
final class TrashFactBookmarks: BookmarkCoding, @unchecked Sendable {
    private let system: SystemSecurityScope
    private let lock = NSLock()
    private var destination: URL?
    init(system: SystemSecurityScope = SystemSecurityScope()) { self.system = system }
    func moveResolution(to url: URL?) { lock.withLock { destination = url } }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if let destination = lock.withLock({ destination }) {
            return ResolvedBookmark(url: destination, stale: false)
        }
        return try system.resolve(data)
    }
}
