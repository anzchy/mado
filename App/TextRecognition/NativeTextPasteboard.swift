import AppKit

@MainActor final class NativeTextPasteboard: TextPasteboardWriting {
    let pasteboard: NSPasteboard
    let writeObjects: @MainActor (NSPasteboard, [NSPasteboardWriting]) -> Bool
    init(_ pasteboard: NSPasteboard,
         writeObjects: @escaping @MainActor (NSPasteboard, [NSPasteboardWriting]) -> Bool = { $0.writeObjects($1) }) {
        self.pasteboard = pasteboard
        self.writeObjects = writeObjects
    }
    @discardableResult func copy(_ text: String) -> Bool {
        let stagingItem = NSPasteboardItem()
        guard stagingItem.setString(text, forType: .string) else { return false }
        let staging = NSPasteboard(name: .init("mado.recognise-text.stage.\(UUID().uuidString)"))
        defer { staging.releaseGlobally() }
        guard writeObjects(staging, [stagingItem]) else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { oldItem in
            let saved = NSPasteboardItem()
            for type in oldItem.types {
                if let data = oldItem.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        } ?? []
        pasteboard.clearContents()
        guard writeObjects(pasteboard, [item]) else {
            pasteboard.clearContents()
            if !previous.isEmpty {
                let restoreItems: [any NSPasteboardWriting] = previous.map { $0 }
                _ = pasteboard.writeObjects(restoreItems)
            }
            return false
        }
        return true
    }
}
