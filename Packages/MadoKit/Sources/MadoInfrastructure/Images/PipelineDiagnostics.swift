import MadoCore

/// Reads each source once. The groups are not one atomic moment: each is consistent within itself.
/// Only the App's ThumbnailDiskCache reports a disk group; another ThumbnailCaching shows it as unknown.
extension ImageIOPipeline: DiagnosticsProviding {
    public func diagnostics() async -> DiagnosticsSnapshot {
        let budget = cache.budget.map { ledger in
            let usage = ledger.usage
            return DiagnosticsSnapshot.Budget(limit: ledger.limit, pinned: usage.pinned, evictable: usage.evictable,
                                              staging: usage.reserved, peak: ledger.peak)
        }
        return DiagnosticsSnapshot(budget: budget, memoryCache: await cache.diagnostics(),
            diskCache: await (thumbnailCache as? ThumbnailDiskCache)?.diagnostics(),
            decoding: await admission.diagnostics())
    }
}
