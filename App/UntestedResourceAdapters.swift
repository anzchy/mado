import Dispatch
import PicseeInfrastructure
import os

/// Untested native sink; field values and mutation ordering are verified through the package port.
struct UntestedNativeResourceSnapshotTrace: ResourceSnapshotTracing {
    private let performance = OSLog(subsystem: "io.github.anzchy.picsee", category: "performance")
    private let cache = Logger(subsystem: "io.github.anzchy.picsee", category: "cache")
    func lookup(isPreview: Bool, hit: Bool) {
        cache.notice("memory tier=\(isPreview ? "preview" : "detail", privacy: .public) outcome=\(hit ? "hit" : "miss", privacy: .public)")
    }
    func snapshot(_ value: ResourceSnapshot) {
        os_signpost(.event, log: performance, name: "ResourceSnapshot",
            "entries=%{public}ld previewBytes=%{public}ld detailBytes=%{public}ld pinnedBytes=%{public}ld reservedBytes=%{public}ld running=%{public}ld waiting=%{public}ld pressure=%{public}@ rss=unknown retainedObjects=unknown",
            value.entries, value.previewBytes, value.detailBytes, value.pinnedBytes, value.reservedBytes,
            value.running, value.waiting, value.pressure.rawValue)
    }
    // #146 counters; the message text is CacheTraceMessage, checked by the package tests.
    func diskLookup(hit: Bool) {
        os_signpost(.event, log: performance, name: "ThumbnailDiskLookup", "%{public}@", CacheTraceMessage.diskLookup(hit: hit))
    }
    func memoryAdmission(isPreview: Bool, bytes: Int) {
        os_signpost(.event, log: performance, name: "MemoryCacheAdmission", "%{public}@",
            CacheTraceMessage.admission(isPreview: isPreview, bytes: bytes))
    }
    func memoryDeparture(isPreview: Bool, bytes: Int, reason: MemoryDepartureReason) {
        os_signpost(.event, log: performance, name: "MemoryCacheEviction", "%{public}@",
            CacheTraceMessage.departure(isPreview: isPreview, bytes: bytes, reason: reason))
    }
}

/// Untested OS input adapter. One consumer forwards observed levels in source-delivery order,
/// first to the shared pipeline, then to the windows (whose grids stop prefetch while it lasts).
final class UntestedNativeMemoryPressureForwarder {
    private let source: any DispatchSourceMemoryPressure
    private let levels: AsyncStream<MemoryPressureLevel>.Continuation
    private let consumer: Task<Void, Never>
    init(pipeline: ImageIOPipeline, windows: @escaping @MainActor (MemoryPressureLevel) -> Void) {
        let (events, levels) = AsyncStream<MemoryPressureLevel>.makeStream()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "io.github.anzchy.picsee.memory-pressure"))
        self.source = source; self.levels = levels
        consumer = Task {
            for await level in events {
                await pipeline.memoryPressure(level)
                await windows(level)
            }
        }
        source.setEventHandler { [weak source] in
            guard let flags = source?.data else { return }
            if flags.contains(.critical) { levels.yield(.critical) }
            else if flags.contains(.warning) { levels.yield(.warning) }
            else if flags.contains(.normal) { levels.yield(.normal) }
        }
        source.activate()
    }
    deinit { source.cancel(); levels.finish(); consumer.cancel() }
}
