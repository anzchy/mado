import Foundation
import Observation
import MadoCore

@MainActor @Observable
public final class CacheSettingsModel {
    public private(set) var sizeBytes: Int64?
    public private(set) var isMeasuring = false
    public private(set) var isClearing = false
    public private(set) var diagnostic: String?
    private let cache: any CacheMaintenance
    private var refreshSequence: UInt64 = 0

    public init(cache: any CacheMaintenance) { self.cache = cache }
    public func refresh() async {
        guard !isClearing else { return }
        await refresh(measureBytes: { [cache] in try await cache.sizeBytes() })
    }

    public func refresh(measureBytes: @escaping @Sendable () async throws -> Int64) async {
        refreshSequence &+= 1
        let sequence = refreshSequence
        sizeBytes = nil
        isMeasuring = true
        let clearIssue = await cache.deferredClearFailure() == nil ? nil : "Cache cleanup failed"
        let writeIssue = await cache.hasWriteFailure() ? "Cache write failed" : nil
        let measured: Int64?
        do { measured = try await measureBytes() }
        catch { measured = nil }
        guard sequence == refreshSequence else { return }
        sizeBytes = measured
        diagnostic = clearIssue ?? writeIssue ?? (measured == nil ? "Cache size unavailable" : nil)
        isMeasuring = false
    }

    public func clear() async {
        await clear(onWaitRegistered: nil)
    }

    public func clear(onWaitRegistered: (@Sendable () -> Void)?) async {
        guard !isClearing else { return }
        isClearing = true
        refreshSequence &+= 1
        sizeBytes = nil
        isMeasuring = true
        var clearFailure: String?
        do { try await cache.clear() }
        catch { clearFailure = "Cache clear failed" }
        if clearFailure == nil {
            await cache.waitForPendingDeletions(onRegistered: onWaitRegistered)
        }
        await refresh(measureBytes: { [cache] in try await cache.sizeBytes() })
        if let clearFailure { diagnostic = clearFailure }
        isClearing = false
    }
}
