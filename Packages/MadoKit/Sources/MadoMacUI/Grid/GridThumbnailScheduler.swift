import AppKit
import MadoCore

enum GridThumbnailPixelSizing {
    static let ceiling = 1024
    static func coverage(tile: NSSize, backingScale: CGFloat) -> ThumbnailCoverage {
        ThumbnailCoverage(width: tile.width * backingScale, height: tile.height * backingScale, ceiling: ceiling)
    }
    /// The edge used when the source ratio is unknown; it also identifies the cell's size tier.
    static func edge(tile: NSSize, backingScale: CGFloat) -> Int {
        coverage(tile: tile, backingScale: backingScale).fallbackEdge
    }
}

/// One window's cancellable thumbnail requests. The source is supplied by the App's lease-bound adapter.
@MainActor final class GridThumbnailScheduler {
    typealias Loader = @Sendable (FolderEntry, AccessRootID, ThumbnailCoverage, DecodePriority) async throws -> (ImageDecodeRequest, DecodedImage)
    var onResult: ((Int, ImageDecodeRequest, DecodedImage) -> Void)?
    var onFailure: ((Int) -> Void)?
    private struct Record {
        let token: UUID
        let itemID: ItemID
        var task: Task<Void, Never>?
        var result: (ImageDecodeRequest, DecodedImage)?
        var failed: Bool
        var failedRevision: FileRevision?
        var priority: DecodePriority
        var wasVisible: Bool
        /// The pipeline refused this prefetch under memory pressure; the next reconcile asks again.
        var deferred = false
    }
    private var snapshot: FolderSnapshot?
    private var records: [Int: Record] = [:]
    private var currentCoverage: ThumbnailCoverage?
    /// Each waiter carries an id, so a cancelled waiter removes only itself.
    private var terminalWaiters: [Int: [(id: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]
    var activeItemIDs: Set<ItemID> { Set(records.values.filter { !$0.deferred }.map(\.itemID)) }
    private enum PinOperation: Sendable {
        case pin(RenderKey, DecodedImage), unpin(RenderKey), settle(CheckedContinuation<Void, Never>)
    }
    private var pinOperations: AsyncStream<PinOperation>.Continuation?
    /// Held results are this window's share of the shared memory budget. One serial consumer applies
    /// pins and unpins in the order they were sent, so an unpin never overtakes its pin.
    var pinning: (any ImagePresentationPinning)? {
        willSet { cancelAll(); pinOperations?.finish(); pinOperations = nil }
        didSet {
            guard let pinning else { return }
            let (operations, continuation) = AsyncStream<PinOperation>.makeStream()
            pinOperations = continuation
            Task {
                for await operation in operations {
                    switch operation {
                    case .pin(let key, let image): await pinning.pin(key, image: image)
                    case .unpin(let key): await pinning.unpin(key)
                    case .settle(let waiter): waiter.resume()
                    }
                }
            }
        }
    }
    /// Says when the pipeline admits prefetch again. While it waits, deferred cells are not asked again (unless they
    /// become visible) and new margin cells are deferred unasked; when it returns the scheduler reconciles once.
    var prefetchResumption: (any PrefetchResuming)?
    private var resumption: Task<Void, Never>?
    private var lastReconcile: (visible: Set<Int>, columns: Int, coverage: ThumbnailCoverage, loader: Loader)?
    /// Under memory pressure only visible cells are requested and held; prefetch resumes when it ends.
    func setMemoryPressure(_ active: Bool) { underPressure = active }
    private var underPressure = false
    /// Returns once every pin and unpin sent so far has reached `pinning`.
    func settlePins() async {
        guard let pinOperations else { return }
        await withCheckedContinuation { pinOperations.yield(.settle($0)) }
    }
    /// Cancels a dropped record and releases its held result.
    private func drop(_ record: Record?) {
        record?.task?.cancel()
        if let key = record?.result?.0.renderKey { pinOperations?.yield(.unpin(key)) }
    }

    func setSnapshot(_ snapshot: FolderSnapshot?) {
        cancelAll()
        self.snapshot = snapshot?.isComplete == true ? snapshot : nil
    }

    func reconcile(visible: Set<Int>, columns: Int, coverage: ThumbnailCoverage, loader: Loader?) {
        guard let snapshot, let loader, coverage.fallbackEdge > 0, let first = visible.min(),
              let last = visible.max(), !snapshot.navigationEntries.isEmpty else {
            cancelAll(); return
        }
        if currentCoverage != coverage { cancelAll(); currentCoverage = coverage }
        lastReconcile = (visible, columns, coverage, loader)
        let margin = max(1, columns) * 2
        let lower = max(0, first - margin)
        let upper = min(snapshot.navigationEntries.count - 1, last + margin)
        let desired = underPressure ? visible.filter { (lower...upper).contains($0) } : Set(lower...upper)
        for index in Array(records.keys) where !desired.contains(index) {
            drop(records.removeValue(forKey: index))
        }
        // Visible requests enter admission first; prefetch may use remaining non-current slots.
        for index in desired.sorted(by: { (visible.contains($0) ? 0 : 1, $0) < (visible.contains($1) ? 0 : 1, $1) }) {
            var previousFailure: FileRevision?
            var keepFailure = false
            if let record = records[index] {
                let isVisible = visible.contains(index)
                if record.deferred && (resumption == nil || isVisible) || isVisible && ((record.priority == .prefetch && record.task != nil)
                    || (record.failed && record.task == nil && !record.wasVisible)) {
                    keepFailure = record.failed
                    previousFailure = record.failedRevision
                    drop(records.removeValue(forKey: index))
                } else {
                    records[index]?.wasVisible = isVisible
                    continue
                }
            }
            let entry = snapshot.navigationEntries[index]
            let token = UUID()
            let priority: DecodePriority = visible.contains(index) ? .visible : .prefetch
            records[index] = Record(token: token, itemID: entry.itemID, task: nil, result: nil,
                failed: keepFailure, failedRevision: previousFailure,
                priority: priority, wasVisible: visible.contains(index))
            // The pipeline still refuses prefetch: the cell waits for the resumption instead of asking now.
            if priority == .prefetch, resumption != nil { records[index]?.deferred = true; continue }
            records[index]?.task = Task { [weak self] in
                do {
                    let loaded: (ImageDecodeRequest, DecodedImage)
                    do { loaded = try await loader(entry, snapshot.version.rootID, coverage, priority) }
                    catch let error as ImageLoadError where error.kind == .sourceChanged {
                        // A new header obtains the new revision. Retry once per live request.
                        try Task.checkCancellation()
                        loaded = try await loader(entry, snapshot.version.rootID, coverage, priority)
                    }
                    guard !Task.isCancelled else { return }
                    self?.finish(index: index, token: token, request: loaded.0, image: loaded.1)
                } catch let error as ImageLoadError where error.kind == .cancelled && priority == .prefetch {
                    // The pipeline refused prefetch under memory pressure: not a failure; the next reconcile asks again.
                    guard !Task.isCancelled else { return }
                    self?.deferPrefetch(index: index, token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(index: index, token: token, error: error)
                }
            }
        }
    }

    private func finish(index: Int, token: UUID, request: ImageDecodeRequest, image: DecodedImage) {
        guard let record = records[index], record.token == token, let snapshot,
              snapshot.navigationEntries.indices.contains(index),
              snapshot.navigationEntries[index].itemID == record.itemID else { return }
        // The source-ratio edge (#161), or the fallback when the loader could not read the ratio first.
        guard let coverage = currentCoverage, request.maximumPixelSize == coverage.fallbackEdge || request.maximumPixelSize
                == coverage.edge(sourceWidth: image.sourcePixelSize.width, sourceHeight: image.sourcePixelSize.height),
              request.renderKey?.itemID == record.itemID,
              request.renderKey?.revision == image.revision,
              image.itemID == record.itemID else {
            fail(index: index, token: token, error: ImageLoadError(.sourceChanged,
                itemID: record.itemID, revision: request.renderKey?.revision))
            return
        }
        records[index]?.result = (request, image)
        if let key = request.renderKey { pinOperations?.yield(.pin(key, image)) }
        records[index]?.task = nil
        records[index]?.failed = false
        records[index]?.failedRevision = nil
        resumeTerminalWaiters(at: index)
        onResult?(index, request, image)
    }

    private func deferPrefetch(index: Int, token: UUID) {
        guard records[index]?.token == token else { return }
        records[index]?.task = nil
        records[index]?.deferred = true
        resumeTerminalWaiters(at: index)
        guard resumption == nil, let prefetchResumption else { return }
        resumption = Task { [weak self] in
            await prefetchResumption.prefetchResumes()
            guard !Task.isCancelled, let self else { return }
            resumption = nil
            guard let last = lastReconcile else { return }
            reconcile(visible: last.visible, columns: last.columns, coverage: last.coverage, loader: last.loader)
        }
    }

    private func fail(index: Int, token: UUID, error: any Error) {
        guard records[index]?.token == token else { return }
        records[index]?.task = nil
        records[index]?.failed = true
        records[index]?.failedRevision = (error as? ImageLoadError)?.revision
        resumeTerminalWaiters(at: index)
        onFailure?(index)
    }

    func result(at index: Int) -> (ImageDecodeRequest, DecodedImage)? { records[index]?.result }
    func token(at index: Int) -> UUID? { records[index]?.token }
    func hasFailure(at index: Int) -> Bool {
        guard let record = records[index] else { return false }
        return record.failed && record.task == nil
    }
    func shouldDisplayFailure(at index: Int) -> Bool { records[index]?.failed == true }
    /// Returns once the record at `index` is terminal, the scheduler cancels its work, or the calling task is cancelled.
    /// After a cancelled return the record may still be pending.
    func waitForTerminal(at index: Int) async {
        if Task.isCancelled { return }
        if let record = records[index], record.task == nil,
           (record.result != nil || record.failed || record.deferred) { return }
        let id = UUID()
        // A cancel can arrive on any thread, before or after the continuation is stored; the main-actor hop runs
        // after the store either way, and finds nothing when the index already ended.
        await withTaskCancellationHandler {
            await withCheckedContinuation { terminalWaiters[index, default: []].append((id, $0)) }
        } onCancel: {
            Task { @MainActor in self.resumeCancelledWaiter(id, at: index) }
        }
    }
    private func resumeTerminalWaiters(at index: Int) {
        for waiter in terminalWaiters.removeValue(forKey: index) ?? [] { waiter.continuation.resume() }
    }
    private func resumeCancelledWaiter(_ id: UUID, at index: Int) {
        guard var waiters = terminalWaiters[index], let position = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: position)
        terminalWaiters[index] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
    }

    func stop() { cancelAll(); snapshot = nil }
    private func cancelAll() {
        resumption?.cancel()
        resumption = nil
        for record in records.values { drop(record) }
        records.removeAll()
        for index in Array(terminalWaiters.keys) { resumeTerminalWaiters(at: index) }
    }
    deinit {
        resumption?.cancel()
        for record in records.values {
            record.task?.cancel()
            if let key = record.result?.0.renderKey { pinOperations?.yield(.unpin(key)) }
        }
        pinOperations?.finish()
    }
}
