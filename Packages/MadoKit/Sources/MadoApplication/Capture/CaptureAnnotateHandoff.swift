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

    public static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
