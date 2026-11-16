import AppKit

@MainActor final class NativeTextPasteboard: TextPasteboardWriting {
    let pasteboard: NSPasteboard
    let writeObjects: @MainActor (NSPasteboard, [NSPasteboardWriting]) -> Bool
    init(_ pasteboard: NSPasteboard,
         writeObjects: @escaping @MainActor (NSPasteboard, [NSPasteboardWriting]) -> Bool = { $0.writeObjects($1) }) {
        self.pasteboard = pasteboard
        self.writeObjects = writeObjects
    }
    @discardableResult func copy(_ text: String) -> Bool { copyText(text) == .copied }

    /// #687 fix r5b (F11): on a failed write the previous clipboard is restored, and the result says whether that is
    /// known to have worked: every representation was read into the snapshot and the restore write succeeded.
    /// NSPasteboard cannot tell promised (lazy) data from data already provided, so the snapshot still reads every
    /// type; one that yields no data counts as lost.
    func copyText(_ text: String) -> TextCopyResult {
        let stagingItem = NSPasteboardItem()
        guard stagingItem.setString(text, forType: .string) else { return .failed(clipboardIntact: true) }
        let staging = NSPasteboard(name: .init("mado.recognise-text.stage.\(UUID().uuidString)"))
        defer { staging.releaseGlobally() }
        guard writeObjects(staging, [stagingItem]) else { return .failed(clipboardIntact: true) }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return .failed(clipboardIntact: true) }
        var complete = true
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { oldItem in
            let saved = NSPasteboardItem()
            for type in oldItem.types {
                if let data = oldItem.data(forType: type) { saved.setData(data, forType: type) } else { complete = false }
            }
            return saved
        } ?? []
        pasteboard.clearContents()
        guard writeObjects(pasteboard, [item]) else {
            pasteboard.clearContents()
            let restored = previous.isEmpty || writeObjects(pasteboard, previous.map { $0 })
            return .failed(clipboardIntact: complete && restored)
        }
        return .copied
    }
}
