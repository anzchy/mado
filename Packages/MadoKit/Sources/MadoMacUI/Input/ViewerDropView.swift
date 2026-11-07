import AppKit

/// The window content surface stays underneath canvas, state buttons and chrome.
public final class ViewerDropView: NSView {
    public var onDragActive: ((Bool) -> Void)?
    private var acceptsDrop: (() -> Bool)?
    private var onDrop: (([URL]) -> Void)?
    public convenience init(frame: NSRect, acceptsDrop: @escaping () -> Bool, onDrop: @escaping ([URL]) -> Void) {
        self.init(frame: frame)
        self.acceptsDrop = acceptsDrop; self.onDrop = onDrop
        registerForDraggedTypes([.fileURL])
    }
    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        var urls: [URL] = []
        if let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) {
            for case let url as URL in objects { urls.append(url) }
        }
        return urls
    }
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = acceptsDrop?() == true && !fileURLs(sender).isEmpty
        onDragActive?(accepted)
        return accepted ? .copy : []
    }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { onDragActive?(false) }
    public override func draggingEnded(_ sender: any NSDraggingInfo) { onDragActive?(false) }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { onDragActive?(false) }
        guard acceptsDrop?() == true else { return false }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
