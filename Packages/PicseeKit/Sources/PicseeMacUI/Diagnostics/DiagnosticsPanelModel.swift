import Foundation
import Observation
import PicseeCore

/// One figure. `title` is a localization key; `value` is a count, a byte size or `DiagnosticsPanelModel.unknown`.
public struct DiagnosticsRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let value: String
}
/// `note`, when present, is a localization key that says what the section's figures count.
public struct DiagnosticsSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let rows: [DiagnosticsRow]
    public let note: String?
}

/// The diagnostics panel's rows (CACHE-04). While visible it reads the source now and then once per interval;
/// hiding cancels the loop, no read starts after it, and a read that was in flight is dropped. Values are counts and
/// sizes only.
@MainActor @Observable
public final class DiagnosticsPanelModel {
    /// Localization key shown for any figure the source could not provide.
    public static let unknown = "Unknown"
    public private(set) var sections: [DiagnosticsSection] = DiagnosticsPanelModel.sections(nil)
    public private(set) var isVisible = false
    private let source: any DiagnosticsProviding
    private let interval: Duration
    private let sleep: (@Sendable (Duration) async throws -> Void)?
    private var loop: Task<Void, Never>?

    /// `sleep` injects a clock for tests; nil sleeps on the real clock.
    public init(source: any DiagnosticsProviding, interval: Duration = .seconds(1),
                sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.source = source; self.interval = interval; self.sleep = sleep
    }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        loop?.cancel()
        loop = nil
        guard visible else { return }
        loop = Task { [weak self, source, interval, sleep] in
            // Cancellation ends the loop at the check after a read, in the pause, or at the check after the pause: a
            // pause can end just before hiding, and the loop gets the main actor back only after the hide (#327).
            repeat {
                let snapshot = await source.diagnostics()
                guard !Task.isCancelled, let self else { break }
                self.sections = Self.sections(snapshot)
            } while await Self.pause(interval, sleep) && !Task.isCancelled
        }
    }

    /// False when the sleep was cancelled. The real clock is called directly: passing `Task.sleep` as a
    /// function value aborted the test process in the concurrency task allocator.
    private nonisolated static func pause(_ interval: Duration,
                                          _ sleep: (@Sendable (Duration) async throws -> Void)?) async -> Bool {
        do {
            if let sleep { try await sleep(interval) } else { try await Task.sleep(for: interval) }
            return true
        } catch { return false }
    }

    /// Eligible folder-granted thumbnails first reuse resident pixels after current content, access,
    /// payload and generation validation. Misses load the disk cache, then decode fresh if needed.
    /// Larger images, file grants and disk-ineligible requests use the ordinary memory path.
    static let memoryLookupNote = "Hits and misses count memory lookups. Eligible folder-granted thumbnails first check resident pixels and count a hit only after current content, access and cache-generation validation. Memory misses fall back to Thumbnail Disk Cache. Larger images, single-file opens without a folder grant, and images not prepared by the disk cache use the ordinary memory path; pinned pixels still show in Entries and Size."
    static let diskLookupNote = "Counts disk-cache fallback loads for eligible grid thumbnails and viewer images up to 1024 px from folders you granted. Validated resident memory hits count under Memory Cache."

    static func sections(_ snapshot: DiagnosticsSnapshot?) -> [DiagnosticsSection] {
        let count = { (value: Int?) in value.map(String.init) ?? unknown }
        let memory = { (value: Int?) in value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? unknown }
        let file = { (value: Int64?) in value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? unknown }
        let budget = snapshot?.budget, cache = snapshot?.memoryCache, disk = snapshot?.diskCache, decoding = snapshot?.decoding
        func section(_ id: String, _ title: String, _ rows: [(String, String, String)], note: String? = nil) -> DiagnosticsSection {
            DiagnosticsSection(id: id, title: title,
                               rows: rows.map { DiagnosticsRow(id: "\(id).\($0.0)", title: $0.1, value: $0.2) }, note: note)
        }
        return [
            section("budget", "Memory Budget", [
                ("limit", "Limit", memory(budget?.limit)), ("pinned", "Pinned", memory(budget?.pinned)),
                ("evictable", "Evictable", memory(budget?.evictable)), ("staging", "Decode Staging", memory(budget?.staging)),
                ("peak", "Peak", memory(budget?.peak))]),
            section("memory", "Memory Cache", [
                ("entries", "Entries", count(cache?.entries)), ("size", "Size", memory(cache?.bytes)),
                ("hits", "Hits", count(cache?.hits)), ("misses", "Misses", count(cache?.misses))],
                note: memoryLookupNote),
            section("disk", "Thumbnail Disk Cache", [
                ("entries", "Indexed Entries", count(disk?.entries)), ("size", "Indexed Size", file(disk?.storedBytes)),
                ("hits", "Hits", count(disk?.hits)), ("misses", "Misses", count(disk?.misses))],
                note: diskLookupNote),
            section("decoding", "Decode Queue", [
                ("running", "Running", count(decoding?.running)), ("waiting", "Waiting", count(decoding?.waiting)),
                ("finished", "Finished Decodes", count(decoding?.finished))]),
        ]
    }
}
