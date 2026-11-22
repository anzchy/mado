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
        guard let record = store.take() else { return nil }
        let age = now.timeIntervalSince(record.createdAt)
        guard age >= 0, age <= freshness else { return nil }
        guard urls.count == 1, let url = urls.first, resolvedPath(url) == record.path else {
            store.write(record)
            return nil
        }
        return url
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
