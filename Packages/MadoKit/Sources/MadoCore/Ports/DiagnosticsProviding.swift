import Foundation

/// Local figures read from the running App for the diagnostics panel (CACHE-04). Every value is measured;
/// a group is nil when its source is absent, and a field is nil when its source could not read it.
/// Counts and sizes only: nothing here names a file or folder.
/// Hits and misses count resolved lookup attempts: a caller that cancels or rejects a result afterwards
/// does not undo its count.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    /// The shared memory ledger, in bytes.
    public struct Budget: Sendable, Equatable {
        public let limit: Int
        public let pinned: Int
        public let evictable: Int
        public let staging: Int
        public let peak: Int
        public init(limit: Int, pinned: Int, evictable: Int, staging: Int, peak: Int) {
            self.limit = limit; self.pinned = pinned; self.evictable = evictable; self.staging = staging; self.peak = peak
        }
    }
    public struct MemoryCache: Sendable, Equatable {
        public let entries: Int
        public let bytes: Int
        public let hits: Int
        public let misses: Int
        public init(entries: Int, bytes: Int, hits: Int, misses: Int) {
            self.entries = entries; self.bytes = bytes; self.hits = hits; self.misses = misses
        }
    }
    /// `entries` and `storedBytes` are what the cache index records (it can list a payload deleted outside the App
    /// until a load repairs it), up to ten seconds old; nil when the index could not be read.
    public struct DiskCache: Sendable, Equatable {
        public let entries: Int?
        public let storedBytes: Int64?
        public let hits: Int
        public let misses: Int
        public init(entries: Int?, storedBytes: Int64?, hits: Int, misses: Int) {
            self.entries = entries; self.storedBytes = storedBytes; self.hits = hits; self.misses = misses
        }
    }
    /// The decode queue: `running` and `waiting` include disk-thumbnail loads, which hold room in the same queue;
    /// `finished` counts only source decodes whose decoder returned, successfully or not.
    public struct Decoding: Sendable, Equatable {
        public let running: Int
        public let waiting: Int
        public let finished: Int
        public init(running: Int, waiting: Int, finished: Int) {
            self.running = running; self.waiting = waiting; self.finished = finished
        }
    }
    public var budget: Budget?
    public var memoryCache: MemoryCache?
    public var diskCache: DiskCache?
    public var decoding: Decoding?
    public init(budget: Budget? = nil, memoryCache: MemoryCache? = nil, diskCache: DiskCache? = nil, decoding: Decoding? = nil) {
        self.budget = budget; self.memoryCache = memoryCache; self.diskCache = diskCache; self.decoding = decoding
    }
}

/// The one read the diagnostics panel makes; it never reaches into cache or admission internals.
public protocol DiagnosticsProviding: Sendable {
    func diagnostics() async -> DiagnosticsSnapshot
}
