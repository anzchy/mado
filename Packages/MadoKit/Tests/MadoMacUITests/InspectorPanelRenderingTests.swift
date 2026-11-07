import AppKit
import SwiftUI
import Testing
import MadoApplication
import MadoCore
@testable import MadoMacUI

private struct EmptyInspectorReader: InspectorMetadataReading {
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata { .init() }
}
private struct FilledInspectorReader: InspectorMetadataReading {
    let value: InspectorMetadata
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata { value }
}

@Test func issue136InspectorFrameLeavesGridTitleAndFooterVisible() {
    // Both pinned pages: default 220; max-width:1050px 195; max-width:720px 220 overlay.
    for (windowWidth, expected) in [
        (1280.0, NSRect(x: 1060, y: 0, width: 220, height: 640)),
        (960.0, NSRect(x: 765, y: 0, width: 195, height: 640)),
        (700.0, NSRect(x: 480, y: 38, width: 220, height: 515))
    ] {
        let bounds = NSRect(x: 0, y: 0, width: windowWidth, height: 640)
        #expect(InspectorPanelLayout.frame(in: bounds, grid: true) == expected)
        #expect(InspectorPanelLayout.frame(in: bounds, grid: false) == expected)
    }
}

@Test func issue136InspectorTypeNamesUseKnownExtensionOrHonestIdentifier() {
    #expect(InspectorPanel.typeName("public.png") == "PNG")
    #expect(InspectorPanel.typeName("com.example.unrecognized-image") == "com.example.unrecognized-image")
}

@Test func issue136EnglishAndChineseLabelsFitTheirColumn() {
    for label in ["Dimensions", "Modified", "Created", "Type", "Size",
                  "尺寸", "修改日期", "创建日期", "类型", "大小"] {
        #expect(InspectorPanelLayout.labelWidth(label) == 48)
    }
}

@Test @MainActor func issue136SmokeInspectorLabelsStayOneLineAtTiledWidths() throws {
    _ = NSApplication.shared
    #expect(InspectorPanelLayout.labelWidth([]) == 48)
    let font = NSFont.systemFont(ofSize: 12)
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    let localizedLabels = [
        ["Dimensions", "Modified", "Created", "Type", "Size"],
        ["尺寸", "修改日期", "创建日期", "类型", "大小"]
    ]
    for panelWidth in [195.0, 220.0] {
        let contentWidth = panelWidth - 34
        for labels in localizedLabels {
            let column = InspectorPanelLayout.labelWidth(labels)
            let widest = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
            #expect(column >= max(48, widest))
            for label in labels {
                let measured = ceil((label as NSString).size(withAttributes: [.font: font]).width)
                #expect(column >= max(48, measured))
                let row = InspectorFieldRow(label: label, value: "PNG", id: "smoke", columnWidth: column)
                    .frame(width: contentWidth, alignment: .leading)
                    .background(Color.white)
                let host = NSHostingView(rootView: row)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 48),
                    styleMask: [], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let renderedHeight = host.fittingSize.height
                #expect(renderedHeight <= lineHeight + 1)
                #expect(renderedHeight >= lineHeight - 1)
                #expect(contentWidth - column - 7 > 0)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let labelEdge = min(bitmap.pixelsWide, Int(ceil(column * scale)))
                let rows = (0..<bitmap.pixelsHigh).filter { y in
                    (0..<labelEdge).contains { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return color.redComponent < 0.7 || color.greenComponent < 0.7 || color.blueComponent < 0.7
                    }
                }
                #expect(!rows.isEmpty)
                if let first = rows.first, let last = rows.last {
                    #expect(CGFloat(last - first + 1) <= lineHeight * scale)
                }
                window.close()
            }
        }
    }
}

// design/prototypes/picsee-browser/states/viewer-inspector.html and viewer-inspector-light.html:
// .inspector dl uses a 7 px column gap and 12 px type; the label and value must remain distinct.
@Test @MainActor func issue136Pages16And34DrawEnglishAndChineseRowsWithoutOverlap() throws {
    _ = NSApplication.shared
    for theme in DesignTheme.allCases {
        for (label, heightRange) in [("Dimensions", 20...30), ("尺寸", 8...15)] {
            let background = theme == .dark ? Color(red: 15/255, green: 17/255, blue: 21/255) : Color.white
            let renderer = ImageRenderer(content: InspectorFieldRow(label: label, value: "6000 × 4000", id: "dimensions")
                .frame(width: 186, height: 24).background(background)
                .environment(\.colorScheme, theme == .dark ? .dark : .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let pixels = NSBitmapImageRep(cgImage: image)
            let base = theme == .dark ? 15.0/255 : 1.0
            let ink = (0..<24).flatMap { y in (0..<186).compactMap { x -> (Int, Int)? in
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      abs(color.redComponent - base) > 0.12 else { return nil }
                return (x, y)
            } }
            let labelInk = ink.filter { $0.0 < 95 }, valueInk = ink.filter { $0.0 >= 95 }
            #expect((labelInk.map(\.0).max() ?? 0) >= 10)
            #expect((labelInk.map(\.0).max() ?? 999) < 48)
            #expect((valueInk.map(\.0).min() ?? 0) >= 100)
            #expect((valueInk.map(\.0).max() ?? 0) >= 175)
            let labelHeight = (labelInk.map(\.1).max() ?? 0) - (labelInk.map(\.1).min() ?? 0) + 1
            let valueHeight = (valueInk.map(\.1).max() ?? 0) - (valueInk.map(\.1).min() ?? 0) + 1
            #expect(heightRange.contains(labelHeight)) // English wraps in the 48 pt CSS column
            #expect((8...15).contains(valueHeight)) // drawn 12 pt monospaced value
        }
    }
}

@Test @MainActor func issue136InspectorPanelUsesPage16And34GeometryAndSurfaceColors() throws {
    _ = NSApplication.shared
    let session = ViewerSession(), model = InspectorModel(reader: EmptyInspectorReader())
    func renderedCSS(_ rgb: [Double]) throws -> [CGFloat] {
        let swatch = ImageRenderer(content: Color(red: rgb[0]/255, green: rgb[1]/255, blue: rgb[2]/255)
            .frame(width: 1, height: 1))
        swatch.scale = 1
        let image = try #require(swatch.cgImage)
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }
    for theme in DesignTheme.allCases {
        let renderer = ImageRenderer(content: InspectorPanel(model: model, session: session,
            close: {}, restoreCanvasFocus: {}, updateFocus: { _ in })
            .frame(height: 500)
            .environment(\.colorScheme, theme == .dark ? .dark : .light))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 220 && image.height == 500)
        let pixels = NSBitmapImageRep(cgImage: image)
        // Pinned pages 16/34: --color-bg and --color-surface, independent of DesignColor.
        let base = try renderedCSS(theme == .dark ? [15, 17, 21] : [255, 255, 255])
        let preview = try renderedCSS(theme == .dark ? [22, 26, 34] : [246, 247, 251])
        for (point, expected) in [(NSPoint(x: 205, y: 400), base),
                                  (NSPoint(x: 205, y: 460), base),
                                  (NSPoint(x: 100, y: 275), base),
                                  (NSPoint(x: 30, y: 85), preview),
                                  (NSPoint(x: 110, y: 105), preview)] {
            let color = try #require(pixels.colorAt(x: Int(point.x), y: Int(point.y))).usingColorSpace(.deviceRGB)!
            for i in 0..<3 {
                let actual = [color.redComponent, color.greenComponent, color.blueComponent][i]
                #expect(abs(actual - expected[i]) < 0.012)
            }
        }
        // Pages 16/34: header 36 pt, 12 pt gap, preview 120 pt, name 14 pt after preview,
        // and five 12 pt metadata rows separated by 13 pt. Assert ink on the drawn panel.
        func inkCount(x: Range<Int>, y: Range<Int>) -> Int {
            y.reduce(0) { count, row in
                count + x.reduce(0) { n, column in
                    guard let color = pixels.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { return n }
                    return n + (abs(color.redComponent - base[0]) > 0.14 ? 1 : 0)
                }
            }
        }
        #expect(inkCount(x: 17..<170, y: 12..<48) > 20) // header
        #expect(inkCount(x: 17..<195, y: 194..<228) > 20) // file name or Unknown
        #expect(inkCount(x: 17..<95, y: 235..<395) > 40) // row labels
        #expect(inkCount(x: 110..<203, y: 235..<395) > 40) // row values
        for y in [52, 185] {
            let color = try #require(pixels.colorAt(x: 100, y: y)?.usingColorSpace(.deviceRGB))
            #expect(abs(color.redComponent - base[0]) < 0.10) // gap can include the preview shadow
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136InspectorPanelRendersKnownHeaderAndActualPreview() async throws {
    _ = NSApplication.shared
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let preview = try Data(contentsOf: fixture)
    let metadata = InspectorMetadata(pixelWidth: 600, pixelHeight: 400, typeIdentifier: "public.png",
        creationDate: Date(timeIntervalSince1970: 1_000), modificationDate: Date(timeIntervalSince1970: 2_000),
        byteSize: Int64(preview.count), thumbnailData: preview)
    let model = InspectorModel(reader: FilledInspectorReader(value: metadata)), session = ViewerSession()
    let url = URL(fileURLWithPath: "/tmp/long-name.png")
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    try await waitUntil { model.value != .loading }
    #expect(model.value == .known(metadata))
    let renderer = ImageRenderer(content: InspectorPanel(model: model, session: session,
        close: {}, restoreCanvasFocus: {}, updateFocus: { _ in }).frame(height: 500))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    #expect(image.width == 220 && image.height == 500)
    let pixels = NSBitmapImageRep(cgImage: image)
    let background = DesignColor.sidebarBackground.components(.light)
    let hasActualPreviewPixel = stride(from: 60, through: 170, by: 10).contains { y in
        stride(from: 25, through: 190, by: 10).contains { x in
            guard let pixel = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return abs(pixel.redComponent - background[0]) > 0.05
                && abs(pixel.greenComponent - background[1]) > 0.05
        }
    }
    #expect(hasActualPreviewPixel)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136InspectorPanelFocusEntersAndEscRestoresCanvas() throws {
    _ = NSApplication.shared
    let session = ViewerSession(), model = InspectorModel(reader: EmptyInspectorReader())
    var updates: [FocusContext] = [], restored = 0, closed = 0
    let host = NSHostingView(rootView: InspectorPanel(model: model, session: session,
        close: { closed += 1 }, restoreCanvasFocus: { restored += 1 }, updateFocus: { updates.append($0) }))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 220, height: 500),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let closeButton = descendants(host).compactMap { $0 as? NSButton }
        .first { $0.accessibilityIdentifier() == "inspector.close" }
    #expect(closeButton?.acceptsFirstResponder == true)
    #expect(closeButton?.focusRingType == .exterior)
    closeButton?.performClick(nil)
    #expect(closed == 1)
    session.setInspectorVisible(true)
    session.tab(reverse: false)
    host.layoutSubtreeIfNeeded()
    try runLoopUntil { !updates.isEmpty }
    #expect(updates.contains(.panel))
    _ = CommandRouter().route(.escape, from: .key, to: session)
    host.layoutSubtreeIfNeeded()
    try runLoopUntil { restored != 0 }
    #expect(restored > 0)
    #expect(session.inspectorFocus.focus == .canvas)
}

@Test @MainActor func issue136ComboGridSearchKeepsEditorWithInspectorOpen() {
    #expect(!InspectorPanel.shouldFocusCloseButton(.textInput, allows: false))
    #expect(InspectorPanel.shouldFocusCloseButton(.textInput, allows: true))
    #expect(InspectorPanel.shouldFocusCloseButton(.panel, allows: false))
}
