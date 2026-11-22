import Foundation

/// #694: the one-shot note the capture helper leaves in the App Group just before it opens a Capture in Mado through
/// Launch Services, so Mado opens that file in Annotate Mode. It names the file only; the File Grant still comes from
/// the Launch Services open, so the note cannot give Mado access to anything.
public struct CaptureAnnotateHandoffRecord: Codable, Equatable, Sendable {
    /// Standardized and symlink-resolved, compared the same way on both sides.
    public let path: String
    public let createdAt: Date

    public init(path: String, createdAt: Date) {
        self.path = path
        self.createdAt = createdAt
    }

    public init(fileURL: URL, createdAt: Date) {
        self.init(path: CaptureAnnotateHandoff.resolvedPath(fileURL), createdAt: createdAt)
    }
}

/// The App Group store of the record. `take` reads and removes it, so one record serves one open.
public protocol CaptureAnnotateHandoffPort: Sendable {
    func write(_ record: CaptureAnnotateHandoffRecord)
    func clear()
    func take() -> CaptureAnnotateHandoffRecord?
}

/// i694-fix1: what an open found in the hand-off store, for the lifecycle notice (no path).
public enum CaptureAnnotateHandoffOutcome: String, Sendable {
    /// A fresh record for the one opened file: Annotate Mode.
    case matched
    /// No record.
    case none
    /// A record outside the freshness window (or from the future); removed.
    case stale
    /// A fresh record for another file; put back for its own open.
    case other
    /// More than one file opened; the record is put back.
    case multi
}

public struct CaptureAnnotateHandoffResult: Equatable, Sendable {
    /// The opened file to annotate, or nil.
    public let url: URL?
    public let outcome: CaptureAnnotateHandoffOutcome
    /// The record's age, coarse: none, <0s, 0-5s, 5-15s, 15-60s, >60s.
    public let ageBucket: String
}

public enum CaptureAnnotateHandoff {
    /// How long after the helper wrote the record Mado still honours it. Launch Services normally delivers the open
    /// within seconds, including a cold launch (not measured; see the #694 handoff); a minute leaves a wide margin and
    /// keeps an unconsumed record (Mado killed before it read it) from annotating a much later open of the same file.
    public static let freshness: TimeInterval = 60

    /// Mado's side, when an open arrives: the opened file to annotate, or nil. Only one file whose resolved path is the
    /// record's, at most `freshness` after the helper wrote it, matches; the record is then used up. A stale or
    /// unreadable record is removed. A fresh record for another file is put back for its own open, which Launch
    /// Services delivers next.
    public static func consume(_ store: any CaptureAnnotateHandoffPort, opened urls: [URL], now: Date) -> URL? {
        resolve(store, opened: urls, now: now).url
    }

    /// `consume`, with the outcome and age bucket for the lifecycle notice. Zero files count as `multi`: not one.
    public static func resolve(_ store: any CaptureAnnotateHandoffPort, opened urls: [URL], now: Date)
        -> CaptureAnnotateHandoffResult {
        guard let record = store.take() else { return CaptureAnnotateHandoffResult(url: nil, outcome: .none, ageBucket: "none") }
        let age = now.timeIntervalSince(record.createdAt)
        let bucket = ageBucket(age)
        guard age >= 0, age <= freshness else { return CaptureAnnotateHandoffResult(url: nil, outcome: .stale, ageBucket: bucket) }
        guard urls.count == 1, let url = urls.first else {
            store.write(record)
            return CaptureAnnotateHandoffResult(url: nil, outcome: .multi, ageBucket: bucket)
        }
        guard resolvedPath(url) == record.path else {
            store.write(record)
            return CaptureAnnotateHandoffResult(url: nil, outcome: .other, ageBucket: bucket)
        }
        return CaptureAnnotateHandoffResult(url: url, outcome: .matched, ageBucket: bucket)
    }

    static func ageBucket(_ age: TimeInterval) -> String {
        if age < 0 { return "<0s" }
        if age < 5 { return "0-5s" }
        if age < 15 { return "5-15s" }
        return age <= freshness ? "15-60s" : ">60s"
    }

    public static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// i694-fix1: every store the hand-off can go through, in order: the App Group defaults, then a file in the App Group
/// container. A write goes to each store, because a suite the system does not actually share fails silently, so
/// nothing can choose one store over the other. `take` takes from each, so all are cleared, and returns the newest
/// record. With no store at all the hand-off is an explicit no-op: nothing is written, nothing is read, and 标注
/// opens the Capture plainly. Cross-process visibility of either store is not verified (device only).
public final class CaptureAnnotateHandoffStores: CaptureAnnotateHandoffPort, @unchecked Sendable {
    public let stores: [any CaptureAnnotateHandoffPort]

    public init(defaults: (any CaptureAnnotateHandoffPort)?, file: (any CaptureAnnotateHandoffPort)?) {
        stores = [defaults, file].compactMap { $0 }
    }

    /// False: the explicit no-op.
    public var isAvailable: Bool { !stores.isEmpty }

    public func write(_ record: CaptureAnnotateHandoffRecord) { stores.forEach { $0.write(record) } }
    public func clear() { stores.forEach { $0.clear() } }
    public func take() -> CaptureAnnotateHandoffRecord? {
        stores.compactMap { $0.take() }.max { $0.createdAt < $1.createdAt }
    }
}
