import CoreGraphics
import Foundation
import PicseeCore

struct ImageCacheRequest: Sendable {
    let key: RenderKey
    let id: UUID
    let image: DecodedImage?
    let sourceChanged: Bool
    let requiresSourceValidation: Bool
    init(key: RenderKey, id: UUID, image: DecodedImage?, sourceChanged: Bool = false, requiresSourceValidation: Bool = false) {
        self.key = key; self.id = id; self.image = image; self.sourceChanged = sourceChanged
        self.requiresSourceValidation = requiresSourceValidation
    }
}

struct ImageCacheUsage: Equatable, Sendable {
    let entries: Int
    let previewBytes: Int
    let detailBytes: Int
    let pinnedBytes: Int
    init(entries: Int, previewBytes: Int, detailBytes: Int, pinnedBytes: Int = 0) {
        self.entries = entries; self.previewBytes = previewBytes; self.detailBytes = detailBytes; self.pinnedBytes = pinnedBytes
    }
    var totalBytes: Int { previewBytes + detailBytes }
    var unpinnedBytes: Int { totalBytes - pinnedBytes }
}

/// Shared process-local pixel storage. Reads remain internal to the image pipeline.
public actor ImageMemoryCache {
    private struct Entry {
        let key: RenderKey
        var image: DecodedImage
        var pins = 0
        var variants: [DecodedImage] = []
        var stale = false
        var accessPermit: AccessWorkPermit?
        // What admission reported, so the departure reports the same bytes whatever the entry holds by then.
        var admittedBytes = 0
    }
    private let capacity: Int
    private var limit: Int
    private var pressurePolicy: MemoryPressurePolicy
    // Oldest first; keys use complete session value equality, without an encoding or digest.
    private var entries: [Entry] = []
    private var pending: [UUID: RenderKey] = [:]
    private var epoch = 0
    private var observations: [UUID: (epoch: Int, itemID: ItemID?)] = [:]
    // Two distinct revision events suffice to detect a conflict with any still-live observation.
    private var recent: [ItemID: [(epoch: Int, revision: FileRevision)]] = [:]
    // Lookups resolved to a hit or a miss since launch, counted where the tracer reports them: per resolved
    // attempt, so a caller that cancels or rejects the result afterwards leaves the count.
    private var hits = 0
    private var misses = 0
    // Admissions and departures for the tracer (#146), reported after the operation so no callback runs under authority.
    private let movementTrace: (any ResourceSnapshotTracing)?
    private var movements: [(isPreview: Bool, bytes: Int, departure: MemoryDepartureReason?)] = []
    private var holdingAuthority = false
    /// Shared with this cache's pipeline admission; nil keeps the cache bounded by its capacity alone.
    nonisolated let budget: MemoryBudget?
    public init(capacity: Int, pressureRecoveryDelay: TimeInterval = 5,
                pressureClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.init(capacity: capacity, budget: nil, pressureRecoveryDelay: pressureRecoveryDelay, pressureClock: pressureClock)
    }
    init(capacity: Int, budget: MemoryBudget?, pressureRecoveryDelay: TimeInterval = 5,
         pressureClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         movementTrace: (any ResourceSnapshotTracing)? = nil) {
        precondition(capacity >= 0); self.capacity = capacity; limit = capacity; self.budget = budget
        self.movementTrace = movementTrace
        pressurePolicy = MemoryPressurePolicy(recoveryDelay: pressureRecoveryDelay, clock: pressureClock)
    }
    func pressure(_ level: MemoryPressureLevel, context: ResourceSnapshotContext? = nil) {
        defer { reportMovements() }
        let previous = pressurePolicy.level
        pressurePolicy.update(level)
        guard previous != pressurePolicy.level else { return }
        emit(context)
        switch level {
        case .normal: trim(to: capacity, context: context)
        case .warning: trim(to: capacity / 2, context: context)
        case .critical: trim(to: 0, context: context)
        }
    }
    func permits(_ priority: DecodePriority) -> Bool { pressurePolicy.permits(priority) }
    func prefetchDelay() -> TimeInterval? { pressurePolicy.prefetchDelay() }
    func image(for key: RenderKey, context: ResourceSnapshotContext? = nil) -> DecodedImage? {
        defer { reportMovements() }
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        if entries[index].accessPermit?.isCurrent == false {
            entries[index].stale = true
            if entries[index].pins == 0 { depart(at: index, .discarded); emit(context); account(context) }
            return nil
        }
        let entry = entries.remove(at: index)
        entries.append(entry)
        emit(context)
        return entry.image
    }
    func insert(_ image: DecodedImage, for key: RenderKey, context: ResourceSnapshotContext? = nil, accessPermit: AccessWorkPermit? = nil) {
        defer { reportMovements() }
        guard image.image.bytesPerRow * image.image.height <= capacity else { return }
        guard pinCount(for: key) == 0 else { return }
        remove(key, context: context)
        admit(Entry(key: key, image: image, accessPermit: accessPermit ?? image.accessPermit))
        emit(context)
        trim(to: limit, context: context)
    }
    func remove(_ key: RenderKey, context: ResourceSnapshotContext? = nil) {
        defer { reportMovements() }
        guard let index = entries.firstIndex(where: { $0.key == key && $0.pins == 0 }) else { return }
        depart(at: index, .discarded); emit(context); account(context)
    }
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage, context: ResourceSnapshotContext? = nil) -> Bool {
        defer { reportMovements() }
        let previousWasRevoked = entries.first(where: { $0.key == key })?.accessPermit?.isCurrent == false
        holdingAuthority = true
        let accepted = (try? AccessWorkPermit.admitting(image.accessPermit) { () -> Bool in
            guard image.itemID == key.itemID, image.revision == key.revision else { return false }
            guard image.accessPermit != nil || !previousWasRevoked else { return false }
            recordRevision(key.revision, for: key.itemID)
            if let index = entries.firstIndex(where: { $0.key == key }) {
                let replacesOrigin = image.accessPermit.map { !$0.canCoalesce(with: entries[index].accessPermit) } ?? false
                if entries[index].pins == 0 || replacesOrigin {
                    if entries[index].pins > 0, entries[index].image.image !== image.image,
                       !entries[index].variants.contains(where: { $0.image === entries[index].image.image }) {
                        entries[index].variants.append(entries[index].image)
                    }
                    entries[index].image = image
                    entries[index].accessPermit = image.accessPermit ?? entries[index].accessPermit
                    if replacesOrigin { entries[index].stale = false }
                } else if entries[index].image.image !== image.image,
                          !entries[index].variants.contains(where: { $0.image === image.image }) {
                    entries[index].variants.append(image)
                }
                entries[index].pins += 1
            } else {
                admit(Entry(key: key, image: image, pins: 1, accessPermit: image.accessPermit))
            }
            return true
        }) ?? false
        holdingAuthority = false
        guard accepted else { return false }
        // Observers may revoke authority; never invoke them under the publication lock.
        emit(context)
        trim(to: limit, context: context)
        return true
    }
    func unpin(_ key: RenderKey, context: ResourceSnapshotContext? = nil) {
        defer { reportMovements() }
        guard let index = entries.firstIndex(where: { $0.key == key }), entries[index].pins > 0 else { return }
        entries[index].pins -= 1
        emit(context)
        if entries[index].pins == 0 {
            if !entries[index].variants.isEmpty { entries[index].variants.removeAll(); emit(context) }
            if entries[index].stale || entries[index].accessPermit?.isCurrent == false || entries[index].image.image.bytesPerRow * entries[index].image.image.height > capacity {
                depart(at: index, .discarded)
                emit(context)
            }
            trim(to: limit, context: context)
        } else { account(context) }
    }
    /// Frees at least `bytes` of evictable pixels, oldest first, so admission can stage a decode.
    func release(bytes: Int, context: ResourceSnapshotContext? = nil) {
        defer { reportMovements() }
        let target = max(0, usage().unpinnedBytes - bytes)
        while usage().unpinnedBytes > target, let index = entries.firstIndex(where: { $0.pins == 0 }) {
            depart(at: index, .budget); emit(context)
        }
        account(context)
    }
    func pinCount(for key: RenderKey) -> Int { entries.first(where: { $0.key == key })?.pins ?? 0 }
    func pendingCount() -> Int { pending.count }
    func trim(to limit: Int, context: ResourceSnapshotContext? = nil) {
        defer { reportMovements() }
        precondition(limit >= 0)
        self.limit = min(capacity, limit)
        while self.limit == 0 || usage().unpinnedBytes > self.limit {
            guard let index = entries.firstIndex(where: { $0.pins == 0 }) else { break }
            depart(at: index, .budget)
            emit(context)
        }
        account(context)
    }
    /// Evictable pixels may use only what pins and admitted decodes leave of the shared budget;
    /// the ledger decides that room under its lock, and the oldest entries go until they fit.
    private func account(_ context: ResourceSnapshotContext? = nil) {
        guard let budget else { return }
        var state = usage()
        while state.unpinnedBytes > budget.resident(pinned: state.pinnedBytes, evictable: state.unpinnedBytes),
              let index = entries.firstIndex(where: { $0.pins == 0 }) {
            depart(at: index, .budget); emit(context)
            state = usage()
        }
    }
    func withObservation<T: Sendable>(itemID: ItemID? = nil,
        _ operation: @Sendable (UUID) async throws -> T) async rethrows -> T {
        let id = UUID()
        observations[id] = (epoch, itemID)
        defer { observations[id] = nil; pruneObservations() }
        return try await operation(id)
    }
    private func pruneObservations() {
        // Only a still-running validation can need an intervening revision, including after eviction.
        recent = recent.reduce(into: [:]) { keptByItem, pair in
            let (item, events) = pair
            let kept = events.filter { event in
                observations.values.contains { ($0.itemID == nil || $0.itemID == item) && $0.epoch < event.epoch }
            }
            if !kept.isEmpty { keptByItem[item] = kept }
        }
    }
    private func recordRevision(_ revision: FileRevision, for item: ItemID) {
        epoch += 1
        var events = recent[item] ?? []
        events.removeAll { $0.revision == revision }
        events.append((epoch, revision))
        if events.count > 2 { events.removeFirst(events.count - 2) }
        recent[item] = events
        pruneObservations()
    }
    func lookup(_ key: RenderKey, observation: UUID? = nil, sourceRevalidated: Bool = false,
                context: ResourceSnapshotContext? = nil) -> ImageCacheRequest {
        defer { reportMovements() }
        guard !Task.isCancelled else {
            return ImageCacheRequest(key: key, id: UUID(), image: nil, sourceChanged: true)
        }
        guard !entries.contains(where: { $0.key.itemID == key.itemID && $0.key.revision == key.revision && $0.stale }) else {
            return ImageCacheRequest(key: key, id: UUID(), image: nil, sourceChanged: true)
        }
        if let observation {
            guard let validation = observations[observation],
                  validation.itemID == nil || validation.itemID == key.itemID else {
                return ImageCacheRequest(key: key, id: UUID(), image: nil, sourceChanged: true)
            }
            if recent[key.itemID]?.contains(where: { $0.epoch > validation.epoch && $0.revision != key.revision }) == true {
                // Either header may have been delayed. Only a new leased source read can resolve this.
                return ImageCacheRequest(key: key, id: UUID(), image: nil, sourceChanged: true, requiresSourceValidation: true)
            }
            // A live pinned revision makes an observed header ambiguous until one leased reread settles it.
            if !sourceRevalidated && entries.contains(where: {
                $0.key.itemID == key.itemID && $0.key.revision != key.revision && $0.pins > 0 && !$0.stale
            }) {
                return ImageCacheRequest(key: key, id: UUID(), image: nil, sourceChanged: true, requiresSourceValidation: true)
            }
        }
        // Revision values are opaque. Reject conflicting observations made during this validation,
        // rather than assuming either mtimes or request-start order identify the newest header.
        if let observation { observations[observation]?.itemID = key.itemID }
        recordRevision(key.revision, for: key.itemID)
        for index in entries.indices where entries[index].key.itemID == key.itemID {
            entries[index].stale = entries[index].stale || entries[index].key.revision != key.revision
        }
        while let index = entries.firstIndex(where: { $0.stale && $0.pins == 0 }) {
            depart(at: index, .discarded); emit(context)
        }
        account(context)
        pending = pending.filter { $0.value.itemID != key.itemID || $0.value.revision == key.revision }
        let request = ImageCacheRequest(key: key, id: UUID(), image: image(for: key, context: context))
        if request.image == nil { pending[request.id] = key; misses += 1 } else { hits += 1 }
        context?.tracer.lookup(isPreview: key.isPreview, hit: request.image != nil)
        return request
    }
    func finish(_ request: ImageCacheRequest, image: DecodedImage?, context: ResourceSnapshotContext? = nil,
                accessPermit: AccessWorkPermit? = nil) -> DecodedImage? {
        defer { reportMovements() }
        guard pending.removeValue(forKey: request.id) == request.key else { return nil }
        var inserted = false
        let accessPermit = accessPermit ?? image?.accessPermit
        holdingAuthority = true
        let result: DecodedImage? = try? AccessWorkPermit.admitting(accessPermit) {
            guard let image, !Task.isCancelled, image.itemID == request.key.itemID,
                  image.revision == request.key.revision else { return nil }
            // Independent waiters can complete after admission removed its shared job. Keep one buffer.
            if let retained = entries.first(where: { $0.key == request.key && !$0.stale }) { return retained.image }
            // Telemetry is an external callback; publish it after releasing authority.
            insert(image, for: request.key, accessPermit: accessPermit)
            inserted = true
            return image
        }
        holdingAuthority = false
        if inserted { emit(context) }
        return result
    }
    private func admit(_ entry: Entry) {
        var entry = entry
        entry.admittedBytes = entry.image.image.bytesPerRow * entry.image.image.height
        entries.append(entry)
        if movementTrace != nil { movements.append((entry.key.isPreview, entry.admittedBytes, nil)) }
    }
    private func depart(at index: Int, _ reason: MemoryDepartureReason) {
        let entry = entries.remove(at: index)
        if movementTrace != nil { movements.append((entry.key.isPreview, entry.admittedBytes, reason)) }
    }
    private func reportMovements() {
        guard !holdingAuthority, let movementTrace, !movements.isEmpty else { return }
        let reported = movements
        movements.removeAll()
        for movement in reported {
            if let reason = movement.departure {
                movementTrace.memoryDeparture(isPreview: movement.isPreview, bytes: movement.bytes, reason: reason)
            } else {
                movementTrace.memoryAdmission(isPreview: movement.isPreview, bytes: movement.bytes)
            }
        }
    }
    private func emit(_ context: ResourceSnapshotContext?) {
        guard let context else { return }
        let state = usage(), activity = context.activity
        context.tracer.snapshot(ResourceSnapshot(entries: state.entries, previewBytes: state.previewBytes,
            detailBytes: state.detailBytes, pinnedBytes: state.pinnedBytes, reservedBytes: activity.reservedBytes,
            running: activity.running, waiting: activity.waiting, pressure: pressurePolicy.level))
    }
    /// Entries and resident bytes now, with the lookup outcomes counted since launch.
    func diagnostics() -> DiagnosticsSnapshot.MemoryCache {
        DiagnosticsSnapshot.MemoryCache(entries: entries.count, bytes: usage().totalBytes, hits: hits, misses: misses)
    }
    func usage() -> ImageCacheUsage {
        var seen: Set<ObjectIdentifier> = [], pinned: Set<ObjectIdentifier> = []
        var preview = 0, detail = 0, pinnedBytes = 0
        // A shared buffer is attributed to detail while any detail key retains it.
        for isPreview in [false, true] {
            for entry in entries where entry.key.isPreview == isPreview {
                for image in [entry.image] + entry.variants {
                    let id = ObjectIdentifier(image.image), cost = image.image.bytesPerRow * image.image.height
                    if seen.insert(id).inserted { if isPreview { preview += cost } else { detail += cost } }
                    if entry.pins > 0, pinned.insert(id).inserted { pinnedBytes += cost }
                }
            }
        }
        return ImageCacheUsage(entries: entries.count, previewBytes: preview, detailBytes: detail, pinnedBytes: pinnedBytes)
    }
}
