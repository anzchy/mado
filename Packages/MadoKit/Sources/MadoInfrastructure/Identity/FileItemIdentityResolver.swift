import Foundation
import MadoCore

public struct FileResourceIdentity: Hashable, Sendable {
    public let volumeUUID: String
    public let fileIdentifier: String
    public init(volumeUUID: String, fileIdentifier: String) {
        self.volumeUUID = volumeUUID; self.fileIdentifier = fileIdentifier
    }
}
public protocol FileIdentityResourceReading: Sendable {
    func identity(for fileURL: URL) throws -> FileResourceIdentity?
}
public struct URLIdentityResourceReader: FileIdentityResourceReading {
    public init() { }
    public func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        // Both keys are available on macOS 14. Encode bytes, never the runtime resource object's description.
        var fresh = fileURL
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.volumeUUIDStringKey, .fileResourceIdentifierKey])
        guard let volume = values.volumeUUIDString, let identifier = values.fileResourceIdentifier as? Data else { return nil }
        return FileResourceIdentity(volumeUUID: volume, fileIdentifier: identifier.base64EncodedString())
    }
}
/// Resolves on its own actor, never MainActor. The caller must already hold its File Grant or root lease.
/// Root paths own identity; resource bytes only let an observed rename retain its established ItemID.
/// Rename associations are session-local; durable rename tracking belongs to the later library/watcher.
public actor FileItemIdentityResolver: ItemIdentityResolving {
    private var root: ItemIdentityRoot?
    private let reader: any FileIdentityResourceReading
    private struct Entry {
        let item: ItemID
        let resource: FileResourceIdentity?
    }
    private var entries: [URL: Entry] = [:]
    private var pathsByResource: [FileResourceIdentity: Set<URL>] = [:]
    private var pathsByItem: [ItemID: Set<URL>] = [:]
    public init(root: ItemIdentityRoot? = nil, reader: any FileIdentityResourceReading = URLIdentityResourceReader()) {
        self.root = root; self.reader = reader
    }
    /// A moved Access Root keeps its session identity history at the new location.
    func rebase(to movedRoot: ItemIdentityRoot) {
        guard let root, root.id == movedRoot.id else { return }
        let old = root.url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let new = movedRoot.url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard old != new else { self.root = movedRoot; return }
        var relocated: [URL: Entry] = [:]
        for (path, entry) in entries {
            let components = path.pathComponents
            guard components.starts(with: old.pathComponents) else { continue }
            let suffix = components.dropFirst(old.pathComponents.count)
            var destination = new
            for component in suffix { destination.appendPathComponent(component) }
            relocated[destination.standardizedFileURL] = entry
        }
        entries = relocated
        rebuildIndexes()
        self.root = movedRoot
    }
    /// A completed scan can retire names that no longer exist without treating a
    /// partial or cancelled scan as evidence of deletion.
    func pruneMissing(in folder: URL, recursive: Bool) {
        let boundary = folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        for path in Array(entries.keys) {
            guard path.pathComponents.starts(with: boundary.pathComponents) else { continue }
            if !recursive && path.deletingLastPathComponent() != boundary { continue }
            if !FileManager.default.fileExists(atPath: path.path) { removeEntry(at: path) }
        }
    }
    private func removeEntry(at path: URL) {
        guard let old = entries.removeValue(forKey: path) else { return }
        if let resource = old.resource {
            pathsByResource[resource]?.remove(path)
            if pathsByResource[resource]?.isEmpty == true { pathsByResource.removeValue(forKey: resource) }
        }
        pathsByItem[old.item]?.remove(path)
        if pathsByItem[old.item]?.isEmpty == true { pathsByItem.removeValue(forKey: old.item) }
    }
    private func putEntry(_ entry: Entry, at path: URL) {
        removeEntry(at: path)
        entries[path] = entry
        if let resource = entry.resource { pathsByResource[resource, default: []].insert(path) }
        pathsByItem[entry.item, default: []].insert(path)
    }
    private func rebuildIndexes() {
        pathsByResource.removeAll(keepingCapacity: true)
        pathsByItem.removeAll(keepingCapacity: true)
        for (path, entry) in entries {
            if let resource = entry.resource { pathsByResource[resource, default: []].insert(path) }
            pathsByItem[entry.item, default: []].insert(path)
        }
    }
    public func identity(for fileURL: URL) throws -> ItemID {
        guard fileURL.isFileURL else { throw FileAccessError.outsideRoot }
        if let root, !AccessBoundary.contains(fileURL, in: root.url) { throw FileAccessError.outsideRoot }
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let resource = try reader.identity(for: path)
        let item: ItemID
        if let existing = entries[path] {
            item = existing.item // Includes replace-at-path, even when resource bytes changed.
        } else if let resource, let oldPath = pathsByResource[resource]?.first(where: {
            !FileManager.default.fileExists(atPath: $0.path)
        }), let renamed = entries[oldPath] {
            item = renamed.item
            removeEntry(at: oldPath)
        } else if let root {
            let boundary = root.url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            let relative = path.pathComponents.dropFirst(boundary.pathComponents.count).joined(separator: "/")
            let candidate = ItemID.rootRelative(rootID: root.id, relativePath: relative)
            if pathsByItem[candidate] != nil {
                // A renamed live item still owns this token. Reusing its vacated name creates another item.
                item = resource.map { .resource(volumeUUID: $0.volumeUUID, fileIdentifier: $0.fileIdentifier) }
                    ?? .ephemeral(UUID())
            } else { item = candidate }
        } else if let resource {
            // File Grants have no AccessRootID. Available resource bytes identify them for this grant session.
            item = .resource(volumeUUID: resource.volumeUUID, fileIdentifier: resource.fileIdentifier)
        } else {
            // No file resource identity: one ephemeral token per canonical File Grant path, for this session only.
            item = .ephemeral(UUID())
        }
        putEntry(Entry(item: item, resource: resource), at: path)
        return item
    }
}
