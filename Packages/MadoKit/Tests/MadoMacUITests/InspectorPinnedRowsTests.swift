import AppKit
import SwiftUI
import Testing
@testable import MadoMacUI

@MainActor private func renderedColor(_ value: PinnedDesign.Color, theme: DesignTheme) throws -> NSColor {
    let renderer = ImageRenderer(content: Color(red: value.red, green: value.green, blue: value.blue)
        .frame(width: 1, height: 1).environment(\.colorScheme, theme == .dark ? .dark : .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image)
        .colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
}

@MainActor private func drawnText(_ value: String, width: CGFloat? = nil) throws -> CGImage {
    let text = Text(verbatim: value).font(.system(size: 12, design: .monospaced))
    if let width {
        let renderer = ImageRenderer(content: text.frame(width: width, alignment: .trailing))
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }
    let renderer = ImageRenderer(content: text)
    renderer.scale = 1
    return try #require(renderer.cgImage)
}

private func inkBounds(_ pixels: NSBitmapImageRep, x: Range<Int>, y: Range<Int>,
                       background: NSColor) -> NSRect? {
    var points: [(Int, Int)] = []
    for row in y {
        for column in x {
            guard let color = pixels.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
                  abs(color.redComponent - background.redComponent) > 0.12 else { continue }
            points.append((column, row))
        }
    }
    guard let first = points.first else { return nil }
    return NSRect(x: points.map(\.0).min() ?? first.0, y: points.map(\.1).min() ?? first.1,
                  width: (points.map(\.0).max() ?? first.0) - (points.map(\.0).min() ?? first.0) + 1,
                  height: (points.map(\.1).max() ?? first.1) - (points.map(\.1).min() ?? first.1) + 1)
}

private func peakGlyphColor(_ pixels: NSBitmapImageRep, x: Range<Int>, y: Range<Int>,
                            background: NSColor) throws -> NSColor {
    let colors = y.flatMap { row in x.compactMap { column in
        pixels.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)
    } }
    return try #require(colors.max { lhs, rhs in
        abs(lhs.redComponent - background.redComponent) < abs(rhs.redComponent - background.redComponent)
    })
}

// The pinned pages give a 48 px label column, 7 px column gap, dt=--color-muted,
// dd=--color-text. A long probe exposes the value-column origin via wrapping.
@Test(.timeLimit(.minutes(2))) @MainActor func issue136SmokeMeasuredLabelColumnKeepsSevenPointValueGap() throws {
    _ = NSApplication.shared
    for panelWidth in [195, 220] {
        let contentWidth = CGFloat(panelWidth - 34)
        for labels in [["Dimensions", "Modified", "Created", "Type", "Size"],
                       ["尺寸", "修改日期", "创建日期", "类型", "大小"]] {
            let column = InspectorPanelLayout.labelWidth(labels)
            let valueWidth = contentWidth - column - 7
            let probe = try #require((1...30).map { String(repeating: "M", count: $0) }.first {
                (try? drawnText($0, width: valueWidth).height) == 15 &&
                (try? drawnText($0, width: valueWidth - 7).height) ?? 0 > 15
            })
            let renderer = ImageRenderer(content: InspectorFieldRow(label: labels[0], value: probe,
                id: "measured-gap", columnWidth: column).frame(width: contentWidth)
                .background(Color.white))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.height == 15,
                    "\(panelWidth) pt panel must give the value exactly the remaining width after the 7 pt gap")
            let origin = Int(column + 7)
            let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
            let valueInk = try #require(inkBounds(NSBitmapImageRep(cgImage: image),
                x: origin..<Int(contentWidth), y: 0..<image.height, background: white))
            let reference = ImageRenderer(content: Text(verbatim: probe)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignColor.textPrimary.color)
                .frame(width: valueWidth, alignment: .trailing).background(Color.white))
            reference.scale = 1
            let referenceImage = try #require(reference.cgImage)
            let referenceInk = try #require(inkBounds(NSBitmapImageRep(cgImage: referenceImage),
                x: 0..<referenceImage.width, y: 0..<referenceImage.height, background: white))
            #expect(abs(valueInk.minX - referenceInk.minX - CGFloat(origin)) <= 1)
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136PinnedInspectorRendersEveryEnglishAndChineseFieldInColumns() throws {
    _ = NSApplication.shared
    for (pageName, theme) in [("viewer-inspector", DesignTheme.dark),
                              ("viewer-inspector-light", DesignTheme.light)] {
        let page = try PinnedDesign.page(pageName)
        let columns = try page.raw(".inspector dl", "grid-template-columns", viewport: 1280).split(separator: " ")
        let gaps = try page.raw(".inspector dl", "gap", viewport: 1280).split(separator: " ")
        let labelWidth = try page.lengthValue(String(columns[0]), viewport: 1280)
        let columnGap = try page.lengthValue(String(gaps[1]), viewport: 1280)
        let background = try renderedColor(page.color(":root", "--color-bg", viewport: 1280), theme: theme)
        let labelColor = try renderedColor(page.color(".inspector dt", "color", viewport: 1280), theme: theme)
        let valueColor = try renderedColor(page.color(":root", "--color-text", viewport: 1280), theme: theme)
        #expect(labelWidth == 48 && columnGap == 7)
        for panelWidth in [220, 195] {
            let contentWidth = panelWidth - 34
            let valueOrigin = Int(labelWidth + columnGap)
            let valueWidth = CGFloat(contentWidth - valueOrigin)
            // Find a probe that fits the CSS value column but wraps when that column loses 7 pt.
            let probe = try #require((1...30).map { String(repeating: "M", count: $0) }.first {
                (try? drawnText($0, width: valueWidth).height) == 15 &&
                (try? drawnText($0, width: valueWidth - 7).height) ?? 0 > 15
            })
            for label in ["Type", "类型"] {
                let renderer = ImageRenderer(content: InspectorFieldRow(label: label, value: probe, id: "gap-probe")
                    .frame(width: CGFloat(contentWidth)).environment(\.colorScheme, theme == .dark ? .dark : .light))
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                #expect(image.height == 15,
                        "\(pageName) \(panelWidth) \(label): value column must start at \(valueOrigin) ±1 pt")
            }
            for (label, value) in [
                ("Dimensions", "6000 × 4000"), ("Type", "PNG"), ("Created", "Unknown"),
                ("Modified", "Unknown"), ("Size", "1 MB"),
                ("尺寸", "6000 × 4000"), ("类型", "PNG"), ("创建日期", "未知"),
                ("修改日期", "未知"), ("大小", "1 MB")
            ] {
                #expect(InspectorPanelLayout.labelWidth(label) == CGFloat(labelWidth))
                let renderer = ImageRenderer(content: InspectorFieldRow(label: label, value: value, id: "test")
                    .frame(width: CGFloat(contentWidth), height: 34)
                    .background(Color(red: background.redComponent, green: background.greenComponent,
                                      blue: background.blueComponent))
                    .environment(\.colorScheme, theme == .dark ? .dark : .light))
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                let pixels = NSBitmapImageRep(cgImage: image)
                let labelRect = try #require(inkBounds(pixels, x: 0..<Int(labelWidth), y: 0..<34,
                    background: background))
                let valueRect = try #require(inkBounds(pixels, x: valueOrigin..<contentWidth, y: 0..<34,
                    background: background))
                #expect(labelRect.maxX <= labelWidth && valueRect.minX >= CGFloat(valueOrigin))
                let actualLabel = try peakGlyphColor(pixels, x: 0..<Int(labelWidth), y: 0..<34,
                    background: background)
                let actualValue = try peakGlyphColor(pixels, x: valueOrigin..<contentWidth, y: 0..<34,
                    background: background)
                for (actual, expected) in [(actualLabel, labelColor), (actualValue, valueColor)] {
                    #expect(abs(actual.redComponent - expected.redComponent) < 0.025)
                    #expect(abs(actual.greenComponent - expected.greenComponent) < 0.025)
                    #expect(abs(actual.blueComponent - expected.blueComponent) < 0.025)
                }
                // The complete value string has the same drawn extent as an unrestricted Text.
                let referenceRenderer = ImageRenderer(content: Text(verbatim: value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: valueColor.redComponent, green: valueColor.greenComponent,
                                           blue: valueColor.blueComponent))
                    .background(Color(red: background.redComponent, green: background.greenComponent,
                                      blue: background.blueComponent)))
                referenceRenderer.scale = 1
                let reference = try #require(referenceRenderer.cgImage)
                let referencePixels = NSBitmapImageRep(cgImage: reference)
                let referenceBackground = background
                let referenceRect = try #require(inkBounds(referencePixels, x: 0..<reference.width,
                    y: 0..<reference.height, background: referenceBackground))
                #expect(abs(valueRect.width - referenceRect.width) <= 2,
                        "\(pageName) \(panelWidth) \(label): value text clipped")
                #expect(abs(valueRect.height - referenceRect.height) <= 2,
                        "\(pageName) \(panelWidth) \(label): value text wrapped or clipped")
            }
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136PinnedInspectorValueColumnStartsAtCSSGap() throws {
    _ = NSApplication.shared
    for (pageName, theme) in [("viewer-inspector", DesignTheme.dark),
                              ("viewer-inspector-light", DesignTheme.light)] {
        let page = try PinnedDesign.page(pageName)
        let columns = try page.raw(".inspector dl", "grid-template-columns", viewport: 1280).split(separator: " ")
        let gaps = try page.raw(".inspector dl", "gap", viewport: 1280).split(separator: " ")
        let labelWidth = try page.lengthValue(String(columns[0]), viewport: 1280)
        let columnGap = try page.lengthValue(String(gaps[1]), viewport: 1280)
        let origin = Int(labelWidth + columnGap)
        let background = try renderedColor(page.color(":root", "--color-bg", viewport: 1280), theme: theme)
        for (panelWidth, probe) in [(220, "界界界界MMMMMMMMMMM"), (195, "界界界界界MMMMMM")] {
            let contentWidth = panelWidth - 34
            // Both probes fill the 48+7 design column. A 7→20 gap wraps them.
            #expect(try drawnText(probe, width: CGFloat(contentWidth - origin)).height == 15)
            #expect(try drawnText(probe, width: CGFloat(contentWidth - origin - 13)).height > 15)
            for label in ["Type", "类型"] {
                let renderer = ImageRenderer(content: InspectorFieldRow(label: label, value: probe, id: "origin")
                    .frame(width: CGFloat(contentWidth))
                    .background(Color(red: background.redComponent, green: background.greenComponent,
                                      blue: background.blueComponent))
                    .environment(\.colorScheme, theme == .dark ? .dark : .light))
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                let pixels = NSBitmapImageRep(cgImage: image)
                let valueInk = try #require(inkBounds(pixels, x: origin..<contentWidth,
                    y: 0..<image.height, background: background))
                // Compare the same glyphs at the same trailing-aligned width. Their left
                // side bearing depends on the runner's font and rasterizer, not the gap.
                let reference = ImageRenderer(content: Text(verbatim: probe)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignColor.textPrimary.color)
                    .frame(width: CGFloat(contentWidth - origin), alignment: .trailing)
                    .background(Color(red: background.redComponent, green: background.greenComponent,
                                      blue: background.blueComponent))
                    .environment(\.colorScheme, theme == .dark ? .dark : .light))
                reference.scale = 1
                let referenceImage = try #require(reference.cgImage)
                let referenceInk = try #require(inkBounds(NSBitmapImageRep(cgImage: referenceImage),
                    x: 0..<referenceImage.width, y: 0..<referenceImage.height, background: background))
                #expect(image.height == 15)
                #expect(abs(valueInk.minX - referenceInk.minX - CGFloat(origin)) <= 1,
                        "\(pageName) \(panelWidth) \(label): value column starts beyond 48+7 pt")
            }
        }
    }
}
