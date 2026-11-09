import Foundation
import MadoCore

/// Opt-in observations of one open-folder request. Production installs no observer.
struct FolderOpenStageEvent: Sendable, CustomStringConvertible {
    enum Outcome: String, Sendable { case entered, completed, rejected }
    let openingID: UUID
    let stage: String
    let outcome: Outcome
    let instant: ContinuousClock.Instant
    let elapsed: Duration
    let reason: String?
    var description: String {
        "\(openingID) \(stage).\(outcome.rawValue) t=+\(elapsed)" + (reason.map { " reason=\($0)" } ?? "")
    }
}

/// Captured once by the opening, so replacing a window's observer cannot steal
/// events from work that was already suspended. No paths or bookmark data are kept.
struct FolderOpenStageRecorder: Sendable {
    private let openingID = UUID()
    private let start = ContinuousClock.now
    let observer: @Sendable (FolderOpenStageEvent) -> Void

    init(observer: @escaping @Sendable (FolderOpenStageEvent) -> Void) { self.observer = observer }

    func record(_ stage: String, _ outcome: FolderOpenStageEvent.Outcome, reason: String? = nil) {
        let instant = ContinuousClock.now
        observer(FolderOpenStageEvent(openingID: openingID, stage: stage, outcome: outcome,
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
