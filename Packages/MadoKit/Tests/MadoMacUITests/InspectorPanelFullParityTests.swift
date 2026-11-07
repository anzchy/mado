import AppKit
import SwiftUI
import Testing
import MadoApplication
import MadoCore
@testable import MadoMacUI

private struct ParityReader: InspectorMetadataReading {
    let metadata: InspectorMetadata
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata { metadata }
}

private func translations(for language: String) throws -> [String: String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("App/Resources/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: [String: Any]])
    var result: [String: String] = [:]
    for key in ["Image Information", "Dimensions", "Type", "Created", "Modified", "Size", "Unknown"] {
        let localized = try #require(strings[key]?["localizations"] as? [String: Any])
        let entry = try #require(localized[language] as? [String: Any])
        let unit = try #require(entry["stringUnit"] as? [String: String])
        guard let value = unit["value"] else { throw PinnedDesign.Error("missing \(language) \(key) translation") }
        result[key] = value
    }
    return result
}

private func ink(_ image: CGImage, background: PinnedDesign.Color) -> (width: Int, height: Int, mask: [Bool]) {
    let pixels = NSBitmapImageRep(cgImage: image)
    let mask = (0..<image.height).flatMap { y in (0..<image.width).map { x in
        guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return abs(color.redComponent - background.red) > 0.12
    } }
    return (image.width, image.height, mask)
}

// Match each actual label/value pair's glyphs against the full panel pixels, then assert
// individual positions and separation from the pinned .inspector dl rule.
@Test(.timeLimit(.minutes(2))) @MainActor func issue136PinnedPagesRenderAllFivePanelRowsInEnglishAndChinese() async throws {
    _ = NSApplication.shared
    for (pageName, theme) in [("viewer-inspector", DesignTheme.dark),
                              ("viewer-inspector-light", DesignTheme.light)] {
        let page = try PinnedDesign.page(pageName)
        let viewport = 1280.0
        let headerHeight = try page.length(".inspector header", "height", viewport: viewport)
        let headerGap = try page.length(".inspector header", "margin-bottom", viewport: viewport)
        let topInset = try page.length(".viewer-body>.inspector", "padding-top", viewport: viewport)
        let previewHeight = try page.length(".inspector-preview", "height", viewport: viewport)
        let gaps = try page.raw(".inspector dl", "gap", viewport: viewport).split(separator: " ")
        let rowGap = try page.lengthValue(String(gaps[0]), viewport: viewport)
        let previewColor = try page.color(".inspector-preview", "background", viewport: viewport)
        let background = try page.color(":root", "--color-bg", viewport: viewport)
        let backgroundView = Color(red: background.red, green: background.green, blue: background.blue)
        #expect(topInset == 0 && headerHeight == 36 && headerGap == 12 && previewHeight == 120 && rowGap == 13)
        for language in ["en", "zh-Hans"] {
            let words = try translations(for: language)
            func word(_ key: String) -> String { words[key]! }
            #expect(word("Dimensions") == (language == "zh-Hans" ? "尺寸" : "Dimensions"))
            let metadata = InspectorMetadata(pixelWidth: 6000, pixelHeight: 4000, typeIdentifier: "public.png")
            let model = InspectorModel(reader: ParityReader(metadata: metadata))
            let url = URL(fileURLWithPath: "/tmp/inspector-parity.png")
            model.select(itemID: nil, url: url, access: .fileGrant(url))
            try await waitUntil { model.value != .loading }
            #expect(model.value == .known(metadata))
            let renderer = ImageRenderer(content: InspectorPanel(model: model, session: ViewerSession(),
                translations: words, close: {}, restoreCanvasFocus: {}, updateFocus: { _ in })
                .frame(width: 220, height: 500)
                .environment(\.colorScheme, theme == .dark ? .dark : .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let panel = ink(image, background: background)
            #expect(panel.width == 220 && panel.height == 500)
            let pixels = NSBitmapImageRep(cgImage: image)
            let swatch = ImageRenderer(content: Color(red: previewColor.red, green: previewColor.green,
                blue: previewColor.blue).frame(width: 1, height: 1))
            swatch.scale = 1
            let swatchImage = try #require(swatch.cgImage)
            let swatchPixel = try #require(NSBitmapImageRep(cgImage: swatchImage)
                .colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            func pixel(_ x: Int, _ y: Int) throws -> NSColor {
                try #require(pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            }
            let previewTop = Int(topInset + headerHeight + headerGap)
            for y in [previewTop, previewTop + Int(previewHeight) - 1] {
                let color = try pixel(100, y)
                #expect(abs(color.redComponent - swatchPixel.redComponent) < 0.012)
                #expect(abs(color.greenComponent - swatchPixel.greenComponent) < 0.012)
                #expect(abs(color.blueComponent - swatchPixel.blueComponent) < 0.012)
            }
            #expect((Int(topInset)..<Int(topInset + headerHeight)).contains {
                y in (17..<170).contains { x in panel.mask[y * 220 + x] }
            })
            let rows = [(word("Dimensions"), "6000 × 4000"), (word("Type"), "PNG"),
                        (word("Created"), word("Unknown")), (word("Modified"), word("Unknown")),
                        (word("Size"), word("Unknown"))]
            let labelColumnWidth = InspectorPanelLayout.labelWidth(rows.map(\.0))
            var previousTop = 0, previousHeight = 0
            for (index, row) in rows.enumerated() {
                let rowRenderer = ImageRenderer(content: InspectorFieldRow(label: row.0, value: row.1,
                    id: "expected-\(index)", columnWidth: labelColumnWidth)
                    .frame(width: 186).background(backgroundView)
                    .environment(\.colorScheme, theme == .dark ? .dark : .light))
                rowRenderer.scale = 1
                let reference = ink(try #require(rowRenderer.cgImage), background: background)
                #expect(reference.width == 186 && reference.height > 0)
                var best = (top: 0, difference: Int.max)
                for top in 205...(420 - reference.height) {
                    var difference = 0
                    for y in 0..<reference.height {
                        for x in 0..<186 {
                            if reference.mask[y * 186 + x] != panel.mask[(top + y) * 220 + (17 + x)] {
                                difference += 1
                            }
                        }
                    }
                    if difference < best.difference { best = (top, difference) }
                }
                let count = reference.mask.filter { $0 }.count
                #expect(best.difference <= max(20, count / 8),
                        "\(pageName) \(language) row \(index) \(row.0)=\(row.1) mismatch \(best.difference)/\(count)")
                if index > 0 {
                    #expect(abs(best.top - previousTop - previousHeight - Int(rowGap)) <= 2,
                            "\(pageName) \(language) row \(index) gap")
                }
                previousTop = best.top; previousHeight = reference.height
            }
        }
    }
}
