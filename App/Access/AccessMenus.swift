import AppKit
import MadoCore

@MainActor final class RecentFolderMenuTarget: NSObject {
    var onOpen: ((RecentFolder) -> Void)?
    @objc func open(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? RecentFolder else { return }
        onOpen?(folder)
    }
}

