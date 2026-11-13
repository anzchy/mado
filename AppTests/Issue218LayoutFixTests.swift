import AppKit
import Testing

@MainActor @Test(.timeLimit(.minutes(3))) func issue218EveryButtonTitleFitsActualControlInBothLanguages() throws {
    let (panel, _) = fixPanel()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    let entries = try #require(catalog["strings"] as? [String: Any])
    func translated(_ original: String, _ language: String) -> String {
        let key = entries[original] != nil ? original : entries.first { _, entry in
            guard let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] else { return false }
            return localizations.values.contains { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String == original }
        }?.key ?? original
        let translation = ((entries[key] as? [String: Any])?["localizations"] as? [String: Any])?[language]
        return ((translation as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? original
    }
    func inspect(_ view: NSView) {
        if let button = view as? NSButton, !button.title.isEmpty {
            let original = button.title
            for language in ["en", "zh-Hans"] {
                let value = translated(original, language)
                button.title = value
                #expect(button.intrinsicContentSize.width <= button.frame.width + 1,
                        "\(language) clipped: \(value), intrinsic=\(button.intrinsicContentSize.width), frame=\(button.frame.width)")
            }
            button.title = original
            #expect(view.superview!.bounds.contains(button.frame), "Button outside pane: \(original)")
            for sibling in view.superview!.subviews where sibling !== view && sibling is NSControl {
                #expect(!button.frame.intersects(sibling.frame), "Button overlaps sibling: \(original)")
            }
        }
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            let original = field.stringValue
            for language in ["en", "zh-Hans"] {
                let value = translated(original, language)
                let size = (value as NSString).boundingRect(
                    with: NSSize(width: field.bounds.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: field.font ?? NSFont.systemFont(ofSize: 13)]).size
                #expect(size.height <= field.bounds.height + 1, "\(language) clipped label: \(value)")
            }
        }
        view.subviews.forEach(inspect)
    }
    inspect(root)
}
