import Foundation
import MadoCore

/// The chosen Capture Folder as the App Group keeps it. `display` is the chosen folder with the home folder as `~`;
/// `fellBack` is true while its bookmark cannot be used and Captures go to ~/Downloads instead.
public struct CaptureFolderRecord: Equatable, Sendable {
    public var bookmark: Data?
    public var display: String
    public var fellBack: Bool

    public init(bookmark: Data?, display: String, fellBack: Bool) {
        self.bookmark = bookmark
        self.display = display
        self.fellBack = fellBack
    }

    public static let downloads = CaptureFolderRecord(bookmark: nil, display: "~/Downloads", fellBack: false)
}

public protocol CaptureFolderPreferencePort: Sendable {
    func folderRecord() async -> CaptureFolderRecord
    func setFolderRecord(_ record: CaptureFolderRecord) async
}

/// The helper's Capture Folder (#685 AC-5, ADR-0021): ~/Downloads (its own entitlement) until the user chooses another
/// folder in the helper's open panel; that folder is kept as the helper's security-scoped bookmark and resolved again
/// after a relaunch. A bookmark that cannot be resolved or opened falls back to ~/Downloads and says so.
public actor CaptureFolderAccess {
    private let scope: any SecurityScope & BookmarkCoding
    private let preferences: any CaptureFolderPreferencePort
    private let downloads: URL
    private let home: URL
    private var active: URL?

    public init(scope: any SecurityScope & BookmarkCoding, preferences: any CaptureFolderPreferencePort,
                downloads: URL, home: URL) {
        self.scope = scope
        self.preferences = preferences
        self.downloads = downloads
        self.home = home
    }

    /// The folder the next Capture is written to.
    /// The chosen folder stays open (its security scope started) until another one is chosen.
    public func currentFolder() async -> URL {
        if let active { return active }
        let stored = await preferences.folderRecord()
        guard let bookmark = stored.bookmark else { return downloads }
        var record = stored
        if let resolved = try? scope.resolve(bookmark), scope.start(resolved.url) {
            active = resolved.url
            if resolved.stale, let fresh = try? scope.create(for: resolved.url) { record.bookmark = fresh }
            record.fellBack = false
        } else {
            record.fellBack = true
        }
        if record != stored { await preferences.setFolderRecord(record) }
        return active ?? downloads
    }

    /// The folder the next Capture is written to, as the thumbnail's status line shows it.
    public func currentDisplay() async -> String {
        Self.display(await currentFolder(), home: home)
    }

    /// Keeps a folder the user chose in the open panel. A bookmark that cannot be made leaves the current folder.
    public func choose(_ url: URL) async throws {
        let bookmark = try scope.create(for: url)
        if let active { scope.stop(active) }
        active = nil
        await preferences.setFolderRecord(CaptureFolderRecord(bookmark: bookmark, display: Self.display(url, home: home),
                                                              fellBack: false))
    }

    /// The path with the user's home folder as `~`.
    public static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
