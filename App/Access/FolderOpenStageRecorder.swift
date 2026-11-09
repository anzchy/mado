import Foundation
import MadoCore

/// Opt-in observations of one open-folder request. Production installs no observer.
struct FolderOpenStageEvent: Sendable, CustomStringConvertible {
    enum Outcome: String, Sendable { case queued, entered, completed, rejected }
    enum Kind: String, Sendable { case stage, job, synchronous, wait }
    let controllerID: UUID
    let jobID: UUID?
    let spanID: UUID?
    let kind: Kind
    let isMainThread: Bool
    let openingID: UUID
    let stage: String
    let outcome: Outcome
    let instant: ContinuousClock.Instant
    let elapsed: Duration
    let reason: String?
    var description: String {
        "controller=\(controllerID) opening=\(openingID) job=\(jobID?.uuidString ?? "none") span=\(spanID?.uuidString ?? "none") kind=\(kind.rawValue) main=\(isMainThread) \(stage).\(outcome.rawValue) t=+\(elapsed)" + (reason.map { " reason=\($0)" } ?? "")
    }
}

/// Captured once by the opening, so replacing a window's observer cannot steal
/// events from work that was already suspended. No paths or bookmark data are kept.
struct FolderOpenStageRecorder: Sendable {
    @TaskLocal static var synchronousContext: FolderOpenStageRecorder?
    let controllerID: UUID
    private let openingID: UUID
    private let start: ContinuousClock.Instant
    private let jobID: UUID?
    private let jobStage: String?
    private let extended: Bool
    let observer: @Sendable (FolderOpenStageEvent) -> Void

    init(observer: @escaping @Sendable (FolderOpenStageEvent) -> Void, controllerID: UUID? = nil, extended: Bool = false) {
        self.observer = observer; self.extended = extended
        self.controllerID = controllerID ?? UUID()
        openingID = UUID(); start = .now; jobID = nil; jobStage = nil
    }
    private init(parent: Self, job: String) {
        observer = parent.observer; controllerID = parent.controllerID
        openingID = parent.openingID; start = parent.start
        jobID = UUID(); jobStage = job; extended = parent.extended
    }
    func queuedJob(_ stage: String) -> Self? {
        guard extended else { return nil }
        let job = Self(parent: self, job: stage)
        job.emit(stage, .queued, kind: .job)
        return job
    }
    func entered() { if let jobStage { emit(jobStage, .entered, kind: .job) } }
    func finished() {
        if let jobStage { emit(jobStage, .completed, kind: .job, reason: Task.isCancelled ? "task-cancelled" : nil) }
    }
    final class Span: @unchecked Sendable {
        fileprivate let trace: FolderOpenStageRecorder
        fileprivate let stage: String
        fileprivate let kind: FolderOpenStageEvent.Kind
        fileprivate let id: UUID
        private let lock = NSLock()
        private var ended = false
        fileprivate init(trace: FolderOpenStageRecorder, stage: String, kind: FolderOpenStageEvent.Kind, id: UUID) {
            self.trace = trace; self.stage = stage; self.kind = kind; self.id = id
        }
        func finish(_ outcome: FolderOpenStageEvent.Outcome = .completed, reason: String? = nil) {
            let first = lock.withLock { if ended { return false }; ended = true; return true }
            if first { trace.emit(stage, outcome, kind: kind, spanID: id, reason: reason) }
        }
    }
    private func beginSpan(_ stage: String, kind: FolderOpenStageEvent.Kind) -> Span {
        let span = Span(trace: self, stage: stage, kind: kind, id: UUID())
        emit(stage, .entered, kind: kind, spanID: span.id)
        return span
    }
    func beginSynchronous(_ stage: String) -> Span { beginSpan(stage, kind: .synchronous) }
    func beginWait(_ stage: String) -> Span { beginSpan(stage, kind: .wait) }
    func synchronous<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let span = beginSynchronous(stage)
        do {
            let result = try Self.$synchronousContext.withValue(self, operation: body)
            span.finish(); return result
        } catch { span.finish(.rejected, reason: Self.errorReason(error)); throw error }
    }
    func waiting<T: Sendable>(_ stage: String, isolation: isolated (any Actor)? = #isolation,
                             _ body: () async throws -> T) async rethrows -> T {
        let span = beginSpan(stage, kind: .wait)
        do { let result = try await body(); span.finish(); return result }
        catch { span.finish(.rejected, reason: Self.errorReason(error)); throw error }
    }
    func record(_ stage: String, _ outcome: FolderOpenStageEvent.Outcome, reason: String? = nil) {
        emit(stage, outcome, kind: .stage, reason: reason)
    }
    private func emit(_ stage: String, _ outcome: FolderOpenStageEvent.Outcome,
                      kind: FolderOpenStageEvent.Kind, spanID: UUID? = nil, reason: String? = nil) {
        let instant = ContinuousClock.now
        observer(FolderOpenStageEvent(controllerID: controllerID, jobID: jobID, spanID: spanID, kind: kind,
            isMainThread: Thread.isMainThread, openingID: openingID, stage: stage, outcome: outcome,
            instant: instant, elapsed: start.duration(to: instant), reason: reason))
    }

    static func errorReason(_ error: any Error) -> String {
        if error is CancellationError { return "cancellation" }
        if let error = error as? FileAccessError {
            switch error {
            case .needsReconnection: return "needs-reconnection"
            case .needsFileReconnection: return "needs-file-reconnection"
            case .fileDeleted: return "file-deleted"
            case .outsideRoot: return "outside-root"
            case .startFailed: return "scope-start-failed"
            case .corruptStore: return "corrupt-store"
            case .invalidFolder: return "invalid-folder"
            case .alreadyGranted: return "already-granted"
            }
        }
        let native = error as NSError
        return "\(String(reflecting: type(of: error))) domain=\(native.domain) code=\(native.code)"
    }
}
