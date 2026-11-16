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
/// Group value (`record` returns nil) no folder is the Capture Folder and the prompt keeps its generic wording.
/// A declined Capture Folder is not offered again until Mado quits: the set lives in memory only, never in
/// preferences. Symlink resolution is synchronous file-system work on the main actor, so the gate resolves the
/// Capture Folder once per App Group value and the image's folder once per item, not on every ←/→ (#686 fix r2).
@MainActor public final class CaptureFolderGrantGate {
    private let record: @Sendable () async -> CaptureFolderRecord?
    private let home: URL
    private let resolve: @Sendable (URL) -> String
    private var declinedPaths: Set<String> = []
    /// The last folder resolved on each side, keyed by its standardized path.
    private var lastFolder: (raw: String, resolved: String)?
    private var lastCaptureFolder: (raw: String, resolved: String)?

    /// `home` is the user's real home folder (the sandbox container's is not where Captures are).
    public init(record: @escaping @Sendable () async -> CaptureFolderRecord?, home: URL,
                resolve: @escaping @Sendable (URL) -> String = { $0.resolvingSymlinksInPath().path }) {
        self.record = record
        self.home = home
        self.resolve = resolve
    }

    public func paging(in folder: URL) async -> FolderGrantPaging {
        let path = Self.resolved(folder, cache: &lastFolder, resolve)
        if declinedPaths.contains(path) { return .stay }
        guard let record = await record() else { return .prompt(.generic) }
        let display = record.fellBack ? CaptureFolderRecord.downloads.display : record.display
        let captureFolder = CaptureFolderAccess.url(forDisplay: display, home: home)
        let capturePath = Self.resolved(captureFolder, cache: &lastCaptureFolder, resolve)
        return capturePath == path ? .prompt(.capture) : .prompt(.generic)
    }

    /// Only a declined Capture Folder prompt is remembered; an ordinary folder keeps asking as before.
    public func declined(_ folder: URL, wording: FolderGrantWording) {
        if wording == .capture { declinedPaths.insert(Self.resolved(folder, cache: &lastFolder, resolve)) }
    }

    /// Symlinks resolved on both sides, so a folder reached through a link, or /tmp against /private/tmp, still matches.
    private static func resolved(_ url: URL, cache: inout (raw: String, resolved: String)?,
                                 _ resolve: (URL) -> String) -> String {
        let standardized = url.standardizedFileURL
        if let cache, cache.raw == standardized.path { return cache.resolved }
        let resolved = resolve(standardized)
        cache = (standardized.path, resolved)
        return resolved
    }
}
