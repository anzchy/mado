import AppKit
import MadoApplication

/// One folder-grant prompt as the controller asks for it; tests answer it in place of the alert and open panel.
struct FolderGrantPromptRequest {
    let folder: URL
    let wording: FolderGrantWording
    let mismatch: Bool
    let selected: (URL) -> Void
    let declined: () -> Void
}

@MainActor enum FolderGrantPrompt {
    /// A Capture Folder gets the capture wording (#686, decision 3.4); a folder that does not hold the image keeps
    /// the mismatch wording either way.
    static func texts(folder: URL, mismatch: Bool, wording: FolderGrantWording,
                      localize: (String) -> String = { String(localized: String.LocalizationValue($0)) })
        -> (title: String, message: String) {
        if wording == .capture, !mismatch {
            return (localize("Browsing Other Captures Needs Folder Access"),
                    String(format: localize("Grant access to “%@” to page through your other captures with ←/→."),
                           folder.lastPathComponent))
        }
        return (localize(mismatch ? "Folder Does Not Contain This Image" : "Browsing Needs Folder Access"),
                String(format: localize("To browse images in “%@”, grant access to its folder."), folder.lastPathComponent))
    }

    /// `declined` runs when the user cancels the alert or the open panel.
    static func request(folder: URL, window: NSWindow, mismatch: Bool = false, wording: FolderGrantWording = .generic,
                        selected: @escaping (URL) -> Void, declined: @escaping () -> Void = {}) {
        let alert = NSAlert()
        let texts = texts(folder: folder, mismatch: mismatch, wording: wording)
        alert.messageText = texts.title
        alert.informativeText = texts.message
        alert.addButton(withTitle: String(localized: "Grant Folder…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { declined(); return }
            let panel = NSOpenPanel()
            panel.title = String(localized: "Grant Folder Access")
            panel.prompt = String(localized: "Grant Folder")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = folder
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { declined(); return }
                // Completion can run while the panel is still attached. Let AppKit
                // finish ending it before the caller can present a mismatch sheet.
                panel.orderOut(nil)
                DispatchQueue.main.async { selected(url) }
            }
        }
    }
}
