import Foundation
import os

/// How a GridFirstThumbnails interval ended: every visible cell terminal, a newer snapshot shown first, or the
/// grid's thumbnails stopped (viewer, lost root) first.
public enum GridFirstThumbnailsOutcome: String, Sendable {
    case complete, superseded, stopped
}

/// #146 (P3-08): GridFirstThumbnails runs from showing a complete snapshot to the first moment every visible cell
/// has its thumbnail or its failure. Paired with FolderScan by generation in scripts/perf/p308-parse.mjs.
@MainActor public protocol GridThumbnailTracing: AnyObject {
    func firstThumbnailsBegin(generation: UInt64, items: Int)
    func firstThumbnailsEnd(generation: UInt64, outcome: GridFirstThumbnailsOutcome, visible: Int, shown: Int, failed: Int)
}

/// The exact message text the parser reads (scripts/perf/fixtures/signpost-messages.json).
enum GridFirstThumbnailsMessage {
    static func begin(generation: UInt64, items: Int) -> String { "generation=\(generation) items=\(items)" }
    static func end(generation: UInt64, outcome: GridFirstThumbnailsOutcome, visible: Int, shown: Int, failed: Int) -> String {
        "outcome=\(outcome.rawValue) generation=\(generation) visible=\(visible) shown=\(shown) failed=\(failed)"
    }
}

/// The default sink: one os_signpost interval per folder open (two calls), so formatting costs nothing that matters.
@MainActor public final class SignpostGridThumbnailTrace: GridThumbnailTracing {
    private let log = OSLog(subsystem: "io.github.anzchy.picsee", category: "grid")
    private var ids: [UInt64: OSSignpostID] = [:]
    public init() { }
    public func firstThumbnailsBegin(generation: UInt64, items: Int) {
        let id = OSSignpostID(log: log)
        ids[generation] = id
        os_signpost(.begin, log: log, name: "GridFirstThumbnails", signpostID: id, "%{public}s",
                    GridFirstThumbnailsMessage.begin(generation: generation, items: items))
    }
    /// An end without a matching begin (another sink began it) is dropped rather than invented.
    public func firstThumbnailsEnd(generation: UInt64, outcome: GridFirstThumbnailsOutcome, visible: Int, shown: Int, failed: Int) {
        guard let id = ids.removeValue(forKey: generation) else { return }
        os_signpost(.end, log: log, name: "GridFirstThumbnails", signpostID: id, "%{public}s",
                    GridFirstThumbnailsMessage.end(generation: generation, outcome: outcome, visible: visible, shown: shown, failed: failed))
    }
}
