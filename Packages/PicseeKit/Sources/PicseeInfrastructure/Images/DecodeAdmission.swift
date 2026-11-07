import Foundation
import PicseeCore

public struct DecodeConfiguration: Sendable {
    public let workers: Int
    public let visible: Int
    public let heavy: Int
    public let budget: Int
    public let cacheCapacity: Int
    public let pressureRecoveryDelay: TimeInterval
    public init(workers: Int = 3, visible: Int = 2, heavy: Int = 1,
                budget: Int = min(512 * 1024 * 1024, Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.08)),
                cacheCapacity: Int? = nil, pressureRecoveryDelay: TimeInterval = 5) {
        precondition(workers > 0 && visible >= 0 && heavy > 0 && budget > 0)
        precondition(cacheCapacity == nil || cacheCapacity! >= 0)
        self.cacheCapacity = cacheCapacity ?? budget / 4
        precondition(pressureRecoveryDelay.isFinite && pressureRecoveryDelay >= 0)
        self.pressureRecoveryDelay = pressureRecoveryDelay
        self.workers = workers; self.visible = visible; self.heavy = heavy; self.budget = budget
    }
}

/// Execution seam: completion means the synchronous decoder has really returned.
public protocol DecodeExecuting: Sendable {
    func submit(_ work: @escaping @Sendable () -> Void)
}
public final class OperationDecodeExecutor: DecodeExecuting, Sendable {
    private let queue: OperationQueue
    public init(workers: Int) {
        queue = OperationQueue()
        queue.name = "io.github.anzchy.mado.first-image-decode"
        queue.maxConcurrentOperationCount = workers
    }
    public func submit(_ work: @escaping @Sendable () -> Void) { queue.addOperation(work) }
}

public actor DecodeDelivery {
    private var result: Result<DecodedImage, Error>?
    private var waiters: [CheckedContinuation<DecodedImage, Error>] = []
    public init() { }
    public func value() async throws -> DecodedImage { try await value(onRegistration: {}) }
    // Handshake seam for queue lifecycle tests; invoked only after a waiter is stored.
    func value(onRegistration: @Sendable () -> Void) async throws -> DecodedImage {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation {
            waiters.append($0)
            onRegistration()
        }
    }
    func finish(_ result: Result<DecodedImage, Error>) {
        precondition(self.result == nil)
        self.result = result
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting { waiter.resume(with: result) }
    }
}
public struct DecodeSubscription: Sendable {
    public let id: UUID
    public let delivery: DecodeDelivery
    let admission: DecodeAdmission
    public func value() async throws -> DecodedImage { try await delivery.value() }
    public func cancel() async { await admission.cancel(id) }
    public func raisePriority(to priority: DecodePriority) async { await admission.raise(id, to: priority) }
}
public struct DecodeActivity: Sendable {
    public let running: Int
    public let nonCurrent: Int
    public let visible: Int
    public let heavy: Int
    public let reservedBytes: Int
    public let waiting: Int
}

public actor DecodeAdmission {
    private let configuration: DecodeConfiguration
    private let executor: any DecodeExecuting
    private let decoder: any ImageDecoding
    private let memory: MemoryBudget?
    private let release: (@Sendable (Int) async -> Void)?
    public init(configuration: DecodeConfiguration, executor: any DecodeExecuting, decoder: any ImageDecoding) {
        self.init(configuration: configuration, executor: executor, decoder: decoder, memory: nil, release: nil)
    }
    /// `release` asks the cache to free at least that many evictable bytes.
    init(configuration: DecodeConfiguration, executor: any DecodeExecuting, decoder: any ImageDecoding,
         memory: MemoryBudget?, release: (@Sendable (Int) async -> Void)?) {
        self.configuration = configuration; self.executor = executor; self.decoder = decoder
        self.memory = memory; self.release = release
    }
    /// Pins were released elsewhere; waiting work may now fit.
    func retry() { drain() }
    // Internal schedule-control seam: completion has removed the job, delivery has not resumed its waiter.
    private var completionBarrier: (@Sendable () async -> Void)?
    func setCompletionBarrier(_ barrier: @escaping @Sendable () async -> Void) {
        completionBarrier = barrier
    }
    public func key(for itemID: ItemID, revision: FileRevision, maximumPixelSize: Int, isPreview: Bool = false) -> RenderKey {
        RenderKey(itemID: itemID, revision: revision, maximumPixelSize: maximumPixelSize, isPreview: isPreview)
    }
    public func image(_ request: ImageDecodeRequest, key: RenderKey, cost: Int, heavy: Bool,
                      priority: DecodePriority, reuseExisting: Bool = true) async throws -> DecodedImage {
        try Task.checkCancellation()
        let subscription = subscribe(request, key: key, cost: cost, heavy: heavy, priority: priority,
                                     reuseExisting: reuseExisting)
        return try await withTaskCancellationHandler {
            if Task.isCancelled { await subscription.cancel() }
            let image = try await subscription.value()
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await subscription.cancel() }
        }
    }
    private struct Job {
        let id: UUID
        let trace: DecodeTrace
        let request: ImageDecodeRequest
        let key: RenderKey
        let cost: Int
        let heavy: Bool
        var priority: DecodePriority
        var admitted: DecodePriority?
        var subscribers: [UUID: DecodeDelivery]
        var cancelled: Set<UUID> = []
        /// A staged job resumes its caller when admitted instead of submitting a decode.
        var hold: CheckedContinuation<Void, Error>?
    }
    private var jobs: [UUID: Job] = [:]
    private var pending: [UUID] = []
    private var keyed: [RenderKey: UUID] = [:]
    /// Source decodes whose decoder returned, once per job however many callers shared it.
    private var finishedDecodes = 0

    public func subscribe(_ request: ImageDecodeRequest, key: RenderKey, cost: Int, heavy: Bool,
                          priority: DecodePriority, reuseExisting: Bool = true) -> DecodeSubscription {
        precondition(cost > 0 && cost <= configuration.budget)
        let id = UUID(), subscriber = UUID(), delivery = DecodeDelivery()
        if reuseExisting, let existing = keyed[key], let existingJob = jobs[existing],
           request.accessPermit.map({ $0.canCoalesce(with: existingJob.request.accessPermit) })
               ?? (existingJob.request.accessPermit == nil) {
            jobs[existing]!.subscribers[subscriber] = delivery
            jobs[existing]!.priority = DecodePriority(rawValue: max(jobs[existing]!.priority.rawValue, priority.rawValue))!
            drain()
            return DecodeSubscription(id: subscriber, delivery: delivery, admission: self)
        }
        if reuseExisting { keyed[key] = id }
        jobs[id] = Job(id: id, trace: DecodeTrace(), request: request, key: key, cost: cost, heavy: heavy,
                       priority: priority, subscribers: [subscriber: delivery])
        pending.append(id)
        drain()
        return DecodeSubscription(id: subscriber, delivery: delivery, admission: self)
    }
    public func activity() -> DecodeActivity {
        let running = jobs.values.filter { $0.admitted != nil }
        return DecodeActivity(running: running.count,
            nonCurrent: running.filter { $0.admitted != .current }.count,
            visible: running.filter { $0.admitted == .visible }.count,
            heavy: running.filter { $0.heavy }.count,
            reservedBytes: running.reduce(0) { $0 + $1.cost }, waiting: pending.count)
    }
    func diagnostics() -> DiagnosticsSnapshot.Decoding {
        let active = activity()
        return DiagnosticsSnapshot.Decoding(running: active.running, waiting: active.waiting, finished: finishedDecodes)
    }
    private var releasing = false
    private func eligible(_ job: Job, _ active: DecodeActivity) -> Bool {
        let sameKeyRunning = jobs.values.contains { $0.key == job.key && $0.admitted != nil }
        return !sameKeyRunning && active.running < configuration.workers &&
            (job.priority == .current || active.nonCurrent < configuration.workers - 1) &&
            (job.priority != .visible || active.visible < configuration.visible) &&
            (!job.heavy || active.heavy < configuration.heavy)
    }
    /// Staging shares the budget with resident pixels. Pins alone may fill it; then only an idle current decode runs.
    /// With a ledger this takes the reservation, so it is asked only of the job about to be admitted.
    private func fits(_ job: Job, _ active: DecodeActivity) -> Bool {
        guard let memory else { return job.cost <= configuration.budget - active.reservedBytes }
        return memory.reserve(job.cost, idleCurrent: job.priority == .current && active.running == 0)
    }
    private func drain() {
        // Stable priority order: FIFO among equal priorities. With finite foreground
        // demand eligible visible work progresses; prefetch has no starvation promise.
        let ordered = { self.pending.sorted(by: { self.jobs[$0]!.priority.rawValue > self.jobs[$1]!.priority.rawValue }) }
        while let id = ordered().first(where: { id in
                let job = jobs[id]!, active = activity()
                return eligible(job, active) && fits(job, active)
            }) {
            // No await between checking all resources and taking them.
            jobs[id]!.admitted = jobs[id]!.priority
            pending.removeAll { $0 == id }
            let request = jobs[id]!.request, decoder = decoder, trace = jobs[id]!.trace
            trace.reserve(jobs[id]!.cost)
            if let hold = jobs[id]!.hold {
                jobs[id]!.hold = nil
                trace.staged("DecodeQueueWait")
                hold.resume()
                continue
            }
            executor.submit {
                let result = trace.decode(request, decoder: decoder)
                Task { await self.finished(id, result: result) }
            }
        }
        // Work that only evictable cache pixels hold back asks the cache for the shortfall, then drains again.
        guard let memory, let release, !releasing else { return }
        let active = activity(), held = memory.usage
        guard held.evictable > 0, let blocked = ordered().first(where: { eligible(jobs[$0]!, active) }) else { return }
        let shortfall = jobs[blocked]!.cost - (configuration.budget - active.reservedBytes - held.pinned - held.evictable)
        // Evicting less than the shortfall admits nothing, except an idle current decode, which needs no evictable bytes left.
        guard shortfall > 0, shortfall <= held.evictable || jobs[blocked]!.priority == .current && active.running == 0 else { return }
        releasing = true
        Task {
            await release(shortfall)
            self.releasing = false
            self.drain()
        }
    }
    /// Holds `cost` of staging while `load` decodes outside the executor (a disk-cache payload, #139). It waits in the
    /// same queue and under the same rules as a source decode, and frees the room when `load` returns or throws.
    func staged(_ request: ImageDecodeRequest, key: RenderKey, cost: Int, priority: DecodePriority,
                load: @Sendable () async throws -> DecodedImage?) async throws -> DecodedImage? {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (hold: CheckedContinuation<Void, Error>) in
                jobs[id] = Job(id: id, trace: DecodeTrace(), request: request, key: key, cost: cost, heavy: false,
                               priority: priority, subscribers: [:], hold: hold)
                pending.append(id)
                drain()
            }
        } onCancel: {
            Task { await self.cancelStaged(id) }
        }
        defer {
            let job = jobs.removeValue(forKey: id)!
            memory?.unreserve(job.cost)
            job.trace.staged("MemoryReservation")
            drain()
        }
        return try await load()
    }
    private func cancelStaged(_ id: UUID) {
        guard let job = jobs[id], job.admitted == nil else { return }
        jobs.removeValue(forKey: id)
        pending.removeAll { $0 == id }
        job.trace.cancelWaiting()
        job.hold?.resume(throwing: CancellationError())
        drain()
    }
    private func finished(_ id: UUID, result: Result<DecodedImage, Error>) async {
        let job = jobs.removeValue(forKey: id)!
        finishedDecodes += 1
        memory?.unreserve(job.cost)
        job.trace.release(result)
        if keyed[job.key] == id { keyed.removeValue(forKey: job.key) }
        drain()
        await completionBarrier?()
        for (subscriber, delivery) in job.subscribers {
            await delivery.finish(job.cancelled.contains(subscriber) ? .failure(CancellationError()) : result)
        }
    }
    func cancel(_ id: UUID) async {
        guard let jobID = jobs.first(where: { $0.value.subscribers[id] != nil })?.key else { return }
        guard !jobs[jobID]!.cancelled.contains(id) else { return }
        jobs[jobID]!.cancelled.insert(id)
        let job = jobs[jobID]!
        if job.cancelled.count == job.subscribers.count {
            job.trace.cancel()
            if keyed[job.key] == jobID { keyed.removeValue(forKey: job.key) }
        }
        if jobs[jobID]!.admitted == nil {
            let delivery = jobs[jobID]!.subscribers.removeValue(forKey: id)!
            jobs[jobID]!.cancelled.remove(id)
            if jobs[jobID]!.subscribers.isEmpty {
                jobs[jobID]!.trace.cancelWaiting()
                jobs.removeValue(forKey: jobID)
                pending.removeAll { $0 == jobID }
            }
            drain()
            await delivery.finish(.failure(CancellationError()))
        }
    }
    func raise(_ id: UUID, to priority: DecodePriority) {
        guard let jobID = jobs.first(where: { $0.value.subscribers[id] != nil })?.key else { return }
        jobs[jobID]!.priority = DecodePriority(rawValue: max(jobs[jobID]!.priority.rawValue, priority.rawValue))!
        drain()
    }
}
