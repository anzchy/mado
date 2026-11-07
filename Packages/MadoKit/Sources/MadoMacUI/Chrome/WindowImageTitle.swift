import AppKit

@MainActor public enum WindowImageTitle {
    public static func apply(to window: NSWindow?, imageURL: URL?) {
        window?.representedURL = imageURL
        window?.title = imageURL?.lastPathComponent ?? "Mado"
    }
}
