import AppKit
import MadoApplication
import MadoCore

@MainActor public enum GridWindowIdentity {
    public static func showFolder(_ folder: URL, in window: NSWindow) {
        window.representedURL = folder
        window.title = folder.lastPathComponent
    }
    public static func enterFolder(_ folder: URL, session: ViewerSession, canvas: CanvasView, window: NSWindow) {
        session.enterFolderGrid(items: [], sourceVersion: .init(0))
        canvas.showFailure()
        showFolder(folder, in: window)
    }
}
