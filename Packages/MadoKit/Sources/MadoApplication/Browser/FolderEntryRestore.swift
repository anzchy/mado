import Foundation
import MadoCore

/// What Cancel Reading returns to (ADR-0010: 回到之前显示的内容).
public enum FolderEntryRestoreTarget: Equatable, Sendable {
    case viewer(URL)
    case grid
    case empty
    /// 「读取失败」 (24F-A): Cancel Reading during its Retry returns to the failed read (#238).
    case readFailed
}

struct FolderEntryRestorePoint {
    let target: FolderEntryRestoreTarget
    let browsing: ViewerSession.BrowsingState
    let scan: FolderScanRestorePoint?
    let filePreviewSet: FilePreviewSet?
}

extension ViewerSession {
    /// Records what the window shows before a folder entry replaces it; an entry already reading keeps its first point.
    public func beginFolderEntry(shownImage: URL?, hasCompleteGrid: Bool) {
        guard folderEntryRestore == nil else { return }
        // A shown image wins, including one previewed from a grid; the grid's state is restored with it.
        let target: FolderEntryRestoreTarget = shownImage.map { .viewer($0) }
            ?? (hasCompleteGrid ? .grid : folderScan?.failure != nil ? .readFailed : .empty)
        folderEntryRestore = FolderEntryRestorePoint(target: target, browsing: browsingState,
            scan: folderScan?.restorePoint, filePreviewSet: filePreviewSet)
        // The folder entry owns navigation while it reads; Cancel puts the File Preview Set back.
        endFilePreviewSet()
    }
    /// Stops the reading scan once and puts back the browsing state, folder source and File Preview Set; nil when no
    /// entry is reading. An incomplete source has no restore point, so only the shown image comes back.
    public func cancelFolderEntry() -> FolderEntryRestoreTarget? {
        guard let point = folderEntryRestore else { return nil }
        folderEntryRestore = nil
        // Back before the folder source, so anything reacting to the restored source sees the set again.
        filePreviewSet = point.filePreviewSet
        // restore() stops the reading scan itself and keeps the restored folder's watch on the same stream.
        if let scan = point.scan, let folderScan {
            folderScan.restore(scan, sort: displayPreferences.folderSort,
                direction: displayPreferences.folderSortDirection)
        } else { cancelFolderReading() }
        restoreBrowsingState(point.browsing)
        return point.target
    }
    public func completeFolderEntry() { folderEntryRestore = nil }
}
