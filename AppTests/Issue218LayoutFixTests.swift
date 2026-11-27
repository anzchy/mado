import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #912: the panel is built in each language (the Capture and About panes take their strings from the injected
// localizer, as the app does), and every title must fit its control with `LayoutFit.margin` to spare. Panes that read
// `String(localized:)` from the main bundle show the English key in this test process; their frames do not depend on
// the text, so the translation is swapped in for those. A failure writes `.build/layout-evidence/` (LayoutFitSupport).
@MainActor private func localizedPanel(_ locale: String) throws -> SettingsPanelWindow {
    let catalog = try captureCatalog(locale)
    let localize: (String) -> String = { catalog[$0] ?? $0 }
    let store = InMemoryDisplayPreferencesStore()
    return SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: store), preferencesStore: store,
        defaults: UserDefaults(suiteName: "issue218-\(locale)-\(UUID().uuidString)")!,
        captureLocalize: localize, aboutLocalizedString: localize)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue218EveryButtonTitleFitsActualControlInBothLanguages(_ locale: String) throws {
    let panel = try localizedPanel(locale)
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    let entries = try #require(catalog["strings"] as? [String: Any])
    func translated(_ original: String) -> String {
        let key = entries[original] != nil ? original : entries.first { _, entry in
            guard let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] else { return false }
            return localizations.values.contains { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String == original }
        }?.key ?? original
        let translation = ((entries[key] as? [String: Any])?["localizations"] as? [String: Any])?[locale]
        return ((translation as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? original
    }
    let test = "issue218EveryButtonTitleFitsActualControlInBothLanguages-\(locale)"
    func inspect(_ view: NSView) {
        if let button = view as? NSButton, !button.title.isEmpty {
            let original = button.title
            let value = translated(original)
            button.title = value
            let textWidth = (value as NSString).size(withAttributes: [.font: button.font ?? NSFont.systemFont(ofSize: 13)]).width
            expectLayoutFits(layoutButtonMeasure(intrinsicWidth: button.intrinsicContentSize.width, textWidth: textWidth,
                                                 frame: button.frame.size),
                             view: button, shown: value, locale: locale, test: test)
            button.title = original
            #expect(view.superview!.bounds.contains(button.frame), "Button outside pane: \(original)")
            for sibling in view.superview!.subviews where sibling !== view && sibling is NSControl {
                #expect(!button.frame.intersects(sibling.frame), "Button overlaps sibling: \(original)")
            }
        }
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            let value = translated(field.stringValue)
            expectLayoutFits(layoutLabelMeasure(value, font: field.font ?? NSFont.systemFont(ofSize: 13),
                                                frame: field.bounds.size),
                             view: field, shown: value, locale: locale, test: test)
        }
        view.subviews.forEach(inspect)
    }
    inspect(root)
}
