import Foundation
import MadoCore

public protocol SidebarFolderEnumerating: Sendable {
    func children(in folder: URL, root: URL) async throws -> [URL]
    func imageCount(in folder: URL, root: URL) async throws -> Int
}

public struct SidebarFolderBrowser: Sendable {
    private let access: any AccessLeasing
    private let enumerator: any SidebarFolderEnumerating
    public init(access: any AccessLeasing, enumerator: any SidebarFolderEnumerating) {
        self.access = access; self.enumerator = enumerator
    }
    public func children(in folder: URL, rootID: AccessRootID) async throws -> [URL] {
        try await access.withLease(.root(rootID, file: folder)) { lease in
            guard AccessBoundary.contains(folder, in: lease.url) else { throw FileAccessError.outsideRoot }
            return try await enumerator.children(in: folder, root: lease.url)
        }
    }
    public func imageCount(in folder: URL, rootID: AccessRootID) async throws -> Int {
        try await access.withLease(.root(rootID, file: folder)) { lease in
            guard AccessBoundary.contains(folder, in: lease.url) else { throw FileAccessError.outsideRoot }
            return try await enumerator.imageCount(in: folder, root: lease.url)
        }
    }
    public func parent(in folder: URL, rootID: AccessRootID) async throws -> URL? {
        try await access.withLease(.root(rootID, file: folder)) { lease in
            guard AccessBoundary.contains(folder, in: lease.url) else { throw FileAccessError.outsideRoot }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            return AccessBoundary.contains(parent, in: lease.url) ? parent : nil
        }
    }
}
