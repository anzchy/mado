import Foundation

/// Which folder-grant prompt ←/→ offers on an image whose folder is not an Access Root (#686, decision 3.4).
public enum FolderGrantWording: Equatable, Sendable {
    case generic, capture
}

public enum FolderGrantPaging: Equatable, Sendable {
    case prompt(FolderGrantWording)
    /// The Capture Folder was declined earlier in this Mado session: ←/→ stays on the one image.
    case stay
}

/// Mado's side of the first-time Capture Folder grant (#686). A folder is the Capture Folder when it is the folder the
/// helper publishes in the App Group (`CaptureFolderRecord.display`, or ~/Downloads while it fell back); with no App
/// Group value (`record` returns nil) no folder is the Capture Folder and the prompt keeps its generic wording. A declined Capture Folder is not offered again until Mado quits:
/// the set lives in memory only, never in preferences.
@MainActor public final class CaptureFolderGrantGate {
    private let record: @Sendable () async -> CaptureFolderRecord?
    private let home: URL
    private var declinedPaths: Set<String> = []

    /// `home` is the user's real home folder (the sandbox container's is not where Captures are).
    public init(record: @escaping @Sendable () async -> CaptureFolderRecord?, home: URL) {
        self.record = record
        self.home = home
    }

    public func paging(in folder: URL) async -> FolderGrantPaging {
        let path = Self.path(folder)
        if declinedPaths.contains(path) { return .stay }
        guard let record = await record() else { return .prompt(.generic) }
        let display = record.fellBack ? CaptureFolderRecord.downloads.display : record.display
        let captureFolder = CaptureFolderAccess.url(forDisplay: display, home: home)
        return Self.path(captureFolder) == path ? .prompt(.capture) : .prompt(.generic)
    }

    /// Only a declined Capture Folder prompt is remembered; an ordinary folder keeps asking as before.
    public func declined(_ folder: URL, wording: FolderGrantWording) {
        if wording == .capture { declinedPaths.insert(Self.path(folder)) }
    }

    /// Symlinks resolved on both sides, so a folder reached through a link, or /tmp against /private/tmp, still matches.
    private static func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
