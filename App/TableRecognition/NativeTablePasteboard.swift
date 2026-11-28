import AppKit
import MadoApplication

/// Copy Table's clipboard write (#874, spec #866 decision 9): one item with an HTML table (Word pastes a bordered
/// table) and tab-separated text (Excel, Numbers, plain-text editors).
@MainActor final class NativeTablePasteboard: TableClipboardWriting {
    let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    func writeTable(html: String, tabSeparated: String) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(html, forType: .html), item.setString(tabSeparated, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
