import Foundation
import MadoCore
import os

public actor RecentFolderStore {
    private nonisolated let storage: RecentFolderStorage
    public var storeCorrupt: Bool { storage.lock.withLock { storage.storeCorrupt } }
    public init(url: URL) { storage = RecentFolderStorage(url: url) }
    public func load() throws -> [RecentFolder] { try storage.lock.withLock { try storage.load() } }
    public func add(_ folder: RecentFolder) throws { try storage.lock.withLock { try storage.add(folder) } }
    /// Serializes a synchronous two-store transaction against normal recent reads/writes.
    nonisolated func withTransaction<T>(_ operation: (URL) throws -> T) rethrows -> T {
        try storage.lock.withLock { try operation(storage.url) }
    }
}

private final class RecentFolderStorage: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var storeCorrupt = false
    let url: URL
    /// New entries remain usable for this launch when an unsupported on-disk version must be preserved.
    private var sessionRecent: [RecentFolder]?
    public init(url: URL) { self.url = url }
    public func load() throws -> [RecentFolder] {
        do {
            var recent = try read(url)
            if let data = try? Data(contentsOf: url), StoredSchema.isInterimEnvelope(data),
               let recovered = try? read(url.appendingPathExtension("recovered")) {
                recent = Array((recovered + recent).reduce(into: [RecentFolder]()) { kept, item in
                    if !kept.contains(where: { $0.rootID == item.rootID || $0.url.standardizedFileURL == item.url.standardizedFileURL }) {
                        kept.append(item)
                    }
                }.prefix(10))
            }
            storeCorrupt = false
            return recent
        } catch is StoredSchema.UnsupportedVersion {
            storeCorrupt = false
            return sessionRecent ?? []
        } catch {
            storeCorrupt = true
            Logger(subsystem: "io.github.anzchy.mado", category: "access").error("RecentStore kind=storeCorrupt")
            return (try? read(url.appendingPathExtension("recovered"))) ?? sessionRecent ?? []
        }
    }
    private func read(_ path: URL) throws -> [RecentFolder] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        switch try StoredSchema.decodeItems(Data(contentsOf: path), as: RecentFolder.self, at: path) {
        case .current(let recent): return recent
        case .unsupported(let version):
            StoredSchema.logUnsupportedOnce(at: path, category: "access", store: "recent-folders", version: version)
            throw StoredSchema.UnsupportedVersion(version: version)
        }
    }
    public func add(_ folder: RecentFolder) throws {
        let old = try load().filter { $0.rootID != folder.rootID && $0.url.standardizedFileURL.path != folder.url.standardizedFileURL.path }
        let recent = Array(([folder] + old).prefix(10))
        let destination = storeCorrupt ? url.appendingPathExtension("recovered") : url
        do { try StoredSchema.writeItems(recent, to: destination) }
        catch is StoredSchema.UnsupportedVersion { sessionRecent = recent }
    }
}
