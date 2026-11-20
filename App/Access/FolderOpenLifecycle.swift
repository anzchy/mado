/// #600 test seam: what happened to one folder-open task. The controller reports these only to
/// `folderOpenLifecycleObserver`, which production leaves nil; nothing here is logged. Events carry a task
/// number and a step name, never a path.
struct FolderOpenLifecycleEvent: Equatable, Sendable, CustomStringConvertible {
    enum Kind: String, Sendable {
        /// The task began running on the main actor.
        case started
        /// The folder scan was handed to the scanner.
        case scanBegan = "scan-began"
        /// The task ran to its end without throwing.
        case completed
        /// The task did not present its result; `reason` says why.
        case rejected
        /// The task threw for a reason other than a rejection (the open's own failure path).
        case threw
    }
    enum Reason: String, Sendable {
        /// A later navigation cancelled this task.
        case taskCancelled = "task-cancelled"
        /// The root was in Lost Access when the open ran, so it showed the waiting page instead of scanning.
        case waitingAccess = "waiting-access"
        /// The scan's first presentation was refused because a later open or input took over.
        case authorityRejected = "authority-rejected"
    }
    /// `grant` is openGrantedFolder's task, `scan` is openFolder's.
    var task: String
    /// Counts tasks per controller, from 1.
    var number: Int
    var kind: Kind
    var reason: Reason?

    var description: String { "\(task)#\(number) \(kind.rawValue)" + (reason.map { " \($0.rawValue)" } ?? "") }
}
