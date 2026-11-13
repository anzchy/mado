import AppKit
import MadoCore

@MainActor final class WorkspaceFileRevealer: FileRevealing {
    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

@MainActor final class PasteboardPathCopier: PathCopying {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
