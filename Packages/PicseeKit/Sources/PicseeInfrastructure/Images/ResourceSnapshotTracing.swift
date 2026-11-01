public struct ResourceSnapshot: Equatable, Sendable {
    public let entries: Int
    public let previewBytes: Int
    public let detailBytes: Int
    public let pinnedBytes: Int
    public let reservedBytes: Int
    public let running: Int
    public let waiting: Int
    public let pressure: MemoryPressureLevel
    public var rss: String { "unknown" }
    public var retainedObjects: String { "unknown" }
}

public enum MemoryDepartureReason: String, Sendable {
    case budget, discarded
}

/// A process-wide telemetry sink. Lookup fields contain no user identity or location.
public protocol ResourceSnapshotTracing: Sendable {
    func lookup(isPreview: Bool, hit: Bool)
    func snapshot(_ snapshot: ResourceSnapshot)
    func diskLookup(hit: Bool)
    func memoryAdmission(isPreview: Bool, bytes: Int)
    func memoryDeparture(isPreview: Bool, bytes: Int, reason: MemoryDepartureReason)
}

extension ResourceSnapshotTracing {
    public func snapshot(_ snapshot: ResourceSnapshot) { }
    public func diskLookup(hit: Bool) { }
    public func memoryAdmission(isPreview: Bool, bytes: Int) { }
    public func memoryDeparture(isPreview: Bool, bytes: Int, reason: MemoryDepartureReason) { }
}

/// Signpost messages for the cache counters, in the format scripts/perf/p308-parse.mjs reads.
public enum CacheTraceMessage {
    public static func diskLookup(hit: Bool) -> String { "outcome=\(hit ? "hit" : "miss")" }
    public static func admission(isPreview: Bool, bytes: Int) -> String { "tier=\(tier(isPreview)) bytes=\(bytes)" }
    public static func departure(isPreview: Bool, bytes: Int, reason: MemoryDepartureReason) -> String {
        "tier=\(tier(isPreview)) bytes=\(bytes) reason=\(reason.rawValue)"
    }
    private static func tier(_ isPreview: Bool) -> String { isPreview ? "preview" : "detail" }
}

struct ResourceSnapshotContext: Sendable {
    let tracer: any ResourceSnapshotTracing
    let activity: DecodeActivity
}
