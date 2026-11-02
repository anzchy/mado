import AppKit
import Testing
import PicseeApplication
@testable import PicseeMacUI

private let page26MissingDetail = "它可能已被删除、放进了废纸篓，或不在原来的磁盘上。如果它在别处，在新位置重新选择它即可继续。"

private func page26CatalogValue(_ key: String, _ language: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardizedFileURL
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any], "Missing page-26 catalog key: \(key)")
    let localizations = try #require(entry["localizations"] as? [String: Any])
    let translation = try #require(localizations[language] as? [String: Any])
    let unit = try #require(translation["stringUnit"] as? [String: Any])
    return try #require(unit["value"] as? String)
}

/// #354 rows2/3: production catalog, not a hand-authored layout-only copy.
/// permission-denied.html case-missing: max-width460, text-wrap:balance, 13px/1.7.
@Test @MainActor func i354CatalogTitlesAndMissingDetailMatchPinnedDesign() throws {
    for (key, chinese) in [("Can’t Find “%@”", "找不到“%@”"), ("Unable to Access “%@”", "无法访问“%@”")] {
        #expect(try page26CatalogValue(key, "en") == key)
        let translated = try page26CatalogValue(key, "zh-Hans")
        #expect(translated == chinese)
        for name in ["待整理", "旅行照片 2026"] {
            #expect(String(format: translated, name) == chinese.replacingOccurrences(of: "%@", with: name))
        }
    }
    #expect(try page26CatalogValue("Not Found", "zh-Hans") == "找不到")
    #expect(try page26CatalogValue("Access Has Expired", "zh-Hans") == "授权失效")
    #expect(try page26CatalogValue("Unavailable", "zh-Hans") == "无法访问")
    let detail = try page26CatalogValue("picsee can’t find “%@”. Choose its location, or choose another folder to continue.", "zh-Hans")
    #expect(detail.replacingOccurrences(of: "\n", with: "") == page26MissingDetail)
    #expect(try page26CatalogValue("picsee can’t find “%@”. Choose its location, or choose another folder to continue.", "en") == "It may have been deleted, put in the Trash, or be on a different disk. If it’s elsewhere, choose it at its new location to continue.")
}

@Test @MainActor func i354ProductionMissingDetailHasTwoBalancedUnclippedLines() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    window.contentView = view
    let raw = try page26CatalogValue("picsee can’t find “%@”. Choose its location, or choose another folder to continue.", "zh-Hans")
    let detail = String(format: raw, "待整理")
    var original: NSRect?
    for dark in [false, true] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for width in [1280, 800, 1280] {
            window.setContentSize(NSSize(width: width, height: width == 800 ? 680 : 800))
            view.display(cause: .notFound, text: .init(title: "找不到“待整理”", detail: detail, waiting: "", reselect: "在新位置选择…", chooseOther: "选择其他文件夹…"))
            view.layoutSubtreeIfNeeded()
            #expect(view.detailLabel.stringValue.replacingOccurrences(of: "\n", with: "") == page26MissingDetail)
            #expect(view.detailLabel.frame.width <= 460)
            let storage = NSTextStorage(attributedString: view.detailLabel.attributedStringValue)
            let manager = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: view.detailLabel.frame.width, height: 10_000))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container); storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            var fragments: [NSRect] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in fragments.append(used) }
            #expect(fragments.count == 2)
            #expect(manager.glyphRange(for: container).length == manager.numberOfGlyphs)
            if fragments.count == 2 {
                #expect(abs(fragments[0].width - fragments[1].width) <= 52.5)
                for fragment in fragments {
                    #expect(abs(fragment.midX - container.containerSize.width / 2) <= 0.5)
                }
            }
            #expect(manager.usedRect(for: container).height <= view.detailLabel.frame.height + 0.5)
            #expect(view.detailLabel.frame.maxY < view.titleLabel.frame.minY)
            #expect(view.reselectButton.frame.maxY < view.detailLabel.frame.minY)
            if width == 1280 {
                if let original { #expect(view.detailLabel.frame == original) } else { original = view.detailLabel.frame }
            }
            await Task.yield()
        }
    }
}
