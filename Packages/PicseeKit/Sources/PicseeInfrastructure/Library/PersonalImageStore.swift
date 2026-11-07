import Foundation
import PicseeCore
import os

/// Favorites and recently viewed images, kept apart from Open Recent's folders (recent-folders.json).
/// Stores references only; access always comes from the Access Root's own bookmark.
/// Calls are actor-serialized and never suspend between reading and writing the file.
public actor PersonalImageStore {
    /// Recently viewed keeps the newest visits; favorites are unbounded.
    public static let recentLimit = 50
    public private(set) var storeCorrupt = false
    private let url: URL
    private var recovery: URL { url.appendingPathExtension("recovered") }
    /// A file that exists but is not a version 1 store.
    private struct Damaged: Error {}
    private struct Contents: Codable {
        var version = 1
        var favorites: [PersonalImageRef] = []
        var recents: [PersonalImageVisit] = []
        /// Only in the recovery file: favorites removed during recovery, so the merge cannot bring
        /// them back from the repaired primary. A later add clears the marker.
        var removedFavorites: [PersonalImageRef]?
        enum CodingKeys: String, CodingKey { case version, favorites, recents, removedFavorites }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = values.contains(.version) ? try values.decode(Int.self, forKey: .version) : 1
            favorites = try values.decode([PersonalImageRef].self, forKey: .favorites)
            recents = try values.decode([PersonalImageVisit].self, forKey: .recents)
            removedFavorites = try values.decodeIfPresent([PersonalImageRef].self, forKey: .removedFavorites)
        }
    }
    private struct VersionHeader: Decodable { let version: Int? }
    private let fileLock: NSLock
    public init(url: URL) {
        self.url = url
        fileLock = FileLocks.shared.lock(for: url)
    }

    /// Newest first.
    public func favorites() throws -> [PersonalImageRef] { try fileLock.withLock { try load().favorites } }
    /// Newest visit first; equal times keep the later visit first.
    public func recents() throws -> [PersonalImageVisit] { try fileLock.withLock { try load().recents } }
    public func isFavorite(_ item: ItemID) throws -> Bool {
        try fileLock.withLock { try load().favorites.contains { $0.itemID == item } }
    }

    /// Returns whether the item is a favorite afterwards.
    public func toggleFavorite(_ ref: PersonalImageRef) throws -> Bool {
        try fileLock.withLock {
            var contents = try load()
            let removed = contents.favorites.contains(ref)
            contents.favorites.removeAll { $0 == ref }
            if !removed { contents.favorites.insert(ref, at: 0) }
            if storeCorrupt {
                var markers = contents.removedFavorites ?? []
                markers.removeAll { $0 == ref }
                if removed { markers.append(ref) }
                contents.removedFavorites = markers.isEmpty ? nil : markers
            }
            try save(contents)
            return !removed
        }
    }
    /// A visit older than every kept one falls outside the bound and is not kept; a revisit is kept at
    /// its own date even when that is older than every other kept visit.
    public func recordVisit(_ ref: PersonalImageRef, at date: Date) throws {
        try fileLock.withLock {
            var contents = try load()
            contents.recents.removeAll { $0.ref == ref }
            let index = contents.recents.firstIndex { $0.viewedAt <= date } ?? contents.recents.endIndex
            contents.recents.insert(PersonalImageVisit(ref: ref, viewedAt: date), at: index)
            contents.recents = Array(contents.recents.prefix(Self.recentLimit))
            // Seeing the image again also refreshes a favorite's file number, in place.
            if let favorite = contents.favorites.firstIndex(of: ref) { contents.favorites[favorite] = ref }
            try save(contents)
        }
    }

    /// A read error other than damage (permissions, I/O) is thrown and nothing is written.
    /// A damaged file is kept as evidence and writes go to the recovery file; once the primary
    /// reads again, the recovery file's writes are merged in and the next write retires it.
    private func load() throws -> Contents {
        let primary: Contents?
        do { primary = try read(url) } catch is StoredSchema.UnsupportedVersion {
            storeCorrupt = false
            return Contents()
        } catch is Damaged {
            storeCorrupt = true
            Logger(subsystem: "io.github.anzchy.mado", category: "library").error("PersonalImageStore kind=storeCorrupt")
            return try readRecovery() ?? Contents()
        }
        storeCorrupt = false
        guard let recovered = try readRecovery() else { return primary ?? Contents() }
        return Self.merge(recovered, into: primary ?? Contents())
    }
    /// A damaged recovery file holds nothing usable and is replaced by the next write.
    private func readRecovery() throws -> Contents? {
        do { return try read(recovery) }
        catch is Damaged { return nil }
        catch is StoredSchema.UnsupportedVersion { return nil }
    }
    private func read(_ path: URL) throws -> Contents? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        if let header = try? JSONDecoder().decode(VersionHeader.self, from: data),
           let version = header.version, version != 1 {
            StoredSchema.logUnsupportedOnce(at: path, category: "library", store: "personal-images", version: version)
            throw StoredSchema.UnsupportedVersion(version: version)
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data), contents.version == 1 else { throw Damaged() }
        return contents
    }
    private func refuseUnsupportedWrite(at path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        if let header = try? JSONDecoder().decode(VersionHeader.self, from: data),
           let version = header.version, version != 1 { throw StoredSchema.UnsupportedVersion(version: version) }
    }
    /// Recovery favorites first, then the primary's others; each image keeps its newest visit
    /// (recovery first on a tie), ordered by visit time and bounded.
    private static func merge(_ recovered: Contents, into primary: Contents) -> Contents {
        var merged = recovered
        let removed = recovered.removedFavorites ?? []
        merged.favorites += primary.favorites.filter { !recovered.favorites.contains($0) && !removed.contains($0) }
        merged.removedFavorites = nil
        var kept: [PersonalImageVisit] = []
        for visit in recovered.recents + primary.recents {
            if let index = kept.firstIndex(where: { $0.ref == visit.ref }) {
                if visit.viewedAt > kept[index].viewedAt { kept[index] = visit }
            } else { kept.append(visit) }
        }
        merged.recents = Array(kept.enumerated()
            .sorted { ($0.element.viewedAt, $1.offset) > ($1.element.viewedAt, $0.offset) }
            .map(\.element).prefix(recentLimit))
        return merged
    }
    private func save(_ contents: Contents) throws {
        let fm = FileManager.default
        try refuseUnsupportedWrite(at: url)
        try refuseUnsupportedWrite(at: recovery)
        let destination = storeCorrupt ? recovery : url
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(contents).write(to: destination, options: .atomic)
        // The primary now holds the merged recovery writes.
        if !storeCorrupt, fm.fileExists(atPath: recovery.path) { try fm.removeItem(at: recovery) }
    }
}

/// One lock per store file in this process: two stores on one file (through any link to it) never
/// interleave one store's read and write with the other's. Each call holds it without suspending.
/// A second store on the same file waits on it by blocking its thread (a cooperative one); the hold is one
/// short file read and write, and the App keeps a single store per file.
private final class FileLocks: @unchecked Sendable {
    static let shared = FileLocks()
    private let guardLock = NSLock()
    private var locks: [String: NSLock] = [:]
    func lock(for url: URL) -> NSLock {
        let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let key = folder.appendingPathComponent(url.lastPathComponent).path
        return guardLock.withLock {
            if let lock = locks[key] { return lock }
            let lock = NSLock()
            locks[key] = lock
            return lock
        }
    }
}
