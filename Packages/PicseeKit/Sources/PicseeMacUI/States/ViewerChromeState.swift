import Foundation
import PicseeApplication

extension ViewerChromeOverlay {
    /// Refresh the label from the load identity, which is retired on cancellation.
    public func refresh(session: ViewerSession) {
        let file = session.imageLoader.fileURL
        let position: String?
        if file != nil, let preview = session.previewSet,
           let current = preview.currentItemID, let index = preview.itemIDs.firstIndex(of: current) {
            position = "\(index + 1) / \(preview.itemIDs.count)"
        } else if session.folderScan?.isScanning == true {
            position = String(localized: "Reading…")
        } else if let file, let member = session.folderScan?.navigationPosition(for: file) {
            position = "\(member.index) / \(member.count)"
        } else {
            position = nil
        }
        refresh(filename: file?.lastPathComponent, position: position)
    }
}
