import Foundation
import Darwin
import MadoCore

public struct AccessRebindUndoToken: Hashable, Sendable {
    let id: UUID
}
public struct AccessRebindResult: Sendable {
    public let rootID: AccessRootID
    public let rootURL: URL
    public let undo: AccessRebindUndoToken
}

/// Exact committed bytes, including absent-file state. Rollback skips unchanged files,
/// so a write denied before touching a file cannot prevent restoration of the first store.
struct AccessStoreBytes: Equatable, Sendable {
    struct File: Equatable, Sendable { let url: URL; let bytes: Data? }
    let files: [File]
    init(urls: [URL]) throws {
        files = try urls.flatMap { [$0, $0.appendingPathExtension("schema"),
                                   $0.appendingPathExtension("recovered"),
                                   $0.appendingPathExtension("recovered.schema")] }.map { url in
            let bytes: Data?
            do { bytes = try Data(contentsOf: url) }
            catch where Self.missing(error) { bytes = nil }
            return File(url: url, bytes: bytes)
        }
    }
    func restore() throws {
        for file in files {
            let current: Data?
            do { current = try Data(contentsOf: file.url) }
            catch where Self.missing(error) { current = nil }
            guard current != file.bytes else { continue }
            if let bytes = file.bytes { try bytes.write(to: file.url, options: .atomic) }
            else { try FileManager.default.removeItem(at: file.url) }
        }
    }
    static func missing(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)
            || ns.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(ns.code)
    }
    static func validate<Value: Codable>(_ url: URL, as type: Value.Type) throws {
        for path in [url, url.appendingPathExtension("recovered")] {
            try StoredSchema.refuseUnsupportedWrite(at: path)
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                guard !StoredSchema.isInterimEnvelope(data) else { throw FileAccessError.corruptStore }
                switch try StoredSchema.decodeItems(data, as: type, at: path) {
                case .current: break
                case .unsupported: throw FileAccessError.corruptStore
                }
            }
            let marker = path.appendingPathExtension("schema")
            if FileManager.default.fileExists(atPath: marker.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]
                guard object?["schemaVersion"] as? Int == StoredSchema.current else { throw FileAccessError.corruptStore }
            }
        }
    }
}

/// References carry no authority. Only confirmed absence drops a reference; an
/// escaping symlink retains its original unresolved reference, never an outside grant.
enum AccessRecentRemap {
    static func remap(_ recent: [RecentFolder], sourceID: AccessRootID, oldRoots: [URL],
                      destinationID: AccessRootID, newRoot: URL,
                      probe: (URL) throws -> Void) -> [RecentFolder] {
        var result: [RecentFolder] = []
        for item in recent {
            guard item.rootID == sourceID else { result.append(item); continue }
            // A newer root can be an ancestor of an older location. Only the
            // recording location identifies this reference’s original suffix.
            // Legacy records retain the latest-first historical fallback.
            let sourceRoots = item.recordedRoot.map { [$0] } ?? oldRoots
            guard let relative = sourceRoots.lazy.compactMap({ relativeComponents(item.url, root: $0) }).first else {
                result.append(item); continue
            }
            let candidate = relative.reduce(newRoot) { $0.appendingPathComponent($1) }
                .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard AccessBoundary.contains(candidate, in: newRoot) else { result.append(item); continue }
            do { try probe(candidate) }
            catch where AccessStoreBytes.missing(error) { continue }
            catch { /* Permission and I/O uncertainty retain the mapped reference. */ }
            let mapped = RecentFolder(rootID: destinationID, url: URL(fileURLWithPath: candidate.path, isDirectory: true),
                                      displayName: item.displayName, openedAt: item.openedAt,
                                      recordedRoot: item.recordedRoot == nil ? nil : newRoot)
            // Preserve an already-present destination entry and its metadata/order.
            let collidesWithDestination = recent.contains { other in
                other.rootID == destinationID && other.url.standardizedFileURL.resolvingSymlinksInPath() == candidate
            }
            if !collidesWithDestination && !result.contains(where: {
                $0.rootID == destinationID && $0.url.standardizedFileURL.resolvingSymlinksInPath() == candidate
            }) { result.append(mapped) }
        }
        return result
    }
    /// Preserve the original relative suffix, including source-side symlink names.
    /// Only root spelling is normalized; descendant symlinks belong to destination validation.
    private static func relativeComponents(_ url: URL, root: URL) -> [String]? {
        let components = url.standardizedFileURL.pathComponents
        let source = root.standardizedFileURL.pathComponents
        if components.starts(with: source) { return Array(components.dropFirst(source.count)) }
        let physicalRoot = physicalLocation(root).pathComponents
        var prefix = URL(fileURLWithPath: "/", isDirectory: true)
        for index in 1..<components.count {
            prefix.appendPathComponent(components[index], isDirectory: true)
            if physicalLocation(prefix).pathComponents == physicalRoot {
                return Array(components.dropFirst(index + 1))
            }
        }
        return nil
    }
    /// Bookmarks can spell /private/var while stored references spell /var.
    /// A missing root cannot be resolved directly, so resolve its existing parent
    /// and append the missing components. This is location evidence only.
    private static func physicalLocation(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        while ancestor.path != "/" {
            if let path = ancestor.path.withCString({ realpath($0, nil) }) {
                resolved = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                free(path)
                break
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
        }
        return suffix.reversed().reduce(resolved) { $0.appendingPathComponent($1, isDirectory: true) }
    }

}
