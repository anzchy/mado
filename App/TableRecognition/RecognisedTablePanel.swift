import AppKit
import MadoApplication
import MadoCore

/// The Recognise Table result panel (#874, state 41 `result`): the original image beside the table, the row and
/// column count with the service name, and Copy Table. Resizable; nothing is copied or dismissed by itself.
@MainActor final class RecognisedTablePanel: NSPanel {
    /// State 41 draws the panel inset 70 × 100 in a 1280 × 800 page: 1080 × 660.
    static let defaultContentSize = NSSize(width: 1080, height: 660)
    static let minimumContentSize = NSSize(width: 640, height: 400)
    /// `.panel .body { grid-template-columns: 230px 1fr }`.
    static let sourceColumnWidth: CGFloat = 230

    let statusLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")
    let sourceCaption = NSTextField(labelWithString: "")
    let sourceImageView = NSImageView()
    let sourceColumn = NSView()
    let tableScroll = NSScrollView()
    let tableText = NSTextView()
    let footerNote = NSTextField(labelWithString: "")
    let copiedLabel = NSTextField(labelWithString: "")
    let copyButton = NSButton()
    let closeButton = NSButton()
    var onCopy: @MainActor () -> Void = {}
    var onClose: @MainActor () -> Void = {}

    init(result: RecognisedTableResult, sourceImage: CGImage?) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize), styleMask: [.titled],
                   backing: .buffered, defer: false)
    }

    func update(_ result: RecognisedTableResult) {}

    static func status(for result: RecognisedTableResult) -> String { "" }
}
