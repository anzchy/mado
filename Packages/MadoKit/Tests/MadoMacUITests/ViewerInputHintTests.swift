import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

private struct InputHintCatalog: Decodable {
    struct Record: Decodable {
        struct Localization: Decodable {
            struct Unit: Decodable { let value: String }
            let stringUnit: Unit?
        }
        let localizations: [String: Localization]?
    }
    let strings: [String: Record]
    func value(_ key: String, _ language: String) -> String? { strings[key]?.localizations?[language]?.stringUnit?.value }
}
@Test func inputHintCatalogExactBilingualValuesAndFilenameFormatting() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let catalog = try JSONDecoder().decode(InputHintCatalog.self,
        from: Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings")))
    let values = [
        ("This File Can’t Be Opened", "This File Can’t Be Opened", "无法打开此文件"),
        ("“%@” isn’t a supported image format.", "“%@” isn’t a supported image format.", "“%@”不是支持的图片格式。"),
        ("None of These Files Can Be Opened", "None of These Files Can Be Opened", "这些文件都无法打开"),
        ("None of the dropped or opened files is a supported image.", "None of the dropped or opened files is a supported image.", "拖入或打开的文件中没有支持的图片。"),
        ("You can also drop images or folders here.", "You can also drop images or folders here.", "也可以拖入图片或文件夹")
    ]
    for (key, en, zh) in values {
        #expect(catalog.value(key, "en") == en)
        #expect(catalog.value(key, "zh-Hans") == zh)
    }
    let key = "“%@” isn’t a supported image format."
    for language in ["en", "zh-Hans"] {
        let format = try #require(catalog.value(key, language))
        #expect(format.components(separatedBy: "%@").count - 1 == 1)
        let names = ["B.jpg", "月亮🌙.jpg", String(repeating: "n", count: 180) + ".png"]
        for name in names {
            let expected = language == "en" ? "“" + name + "” isn’t a supported image format." : "“" + name + "”不是支持的图片格式。"
            #expect(String(format: format, name) == expected)
        }
    }
}

@MainActor private func inputHintViews(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { inputHintViews($0) }
}
@MainActor private func inputHintVisibleInk(_ content: NSView, in rect: NSRect) throws -> Int {
    let crop = rect.integral.intersection(content.bounds)
    #expect(!crop.isEmpty)
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(crop.width), pixelsHigh: Int(crop.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = crop.size
    content.cacheDisplay(in: crop, to: rep)
    var ink = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.alphaComponent > 0.1 && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 { ink += 1 }
        }
    }
    return ink
}

@Test @MainActor func inputHintActualStaticTextResponsiveAndOutsideKeyLoop() throws {
    for width: CGFloat in [960, 360] {
        let scene = StatesScene(width: width)
        defer { scene.session.closeImage(); scene.window.close() }
        scene.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        scene.window.autorecalculatesKeyViewLoop = false
        scene.window.appearance = NSAppearance(named: .aqua)
        scene.window.orderFront(nil)
        scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
        scene.content.layoutSubtreeIfNeeded(); scene.content.displayIfNeeded()
        let nodes = inputHintViews(scene.state)
        print("inputHint AX", width, nodes.map { ($0.accessibilityRole()?.rawValue, $0.accessibilityIdentifier(), $0.accessibilityLabel()) })
        let hint = try #require(nodes.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "first-launch.shortcut" })
        let button = try #require(scene.state.buttons.first)
        #expect(scene.state.textLines == ["Drop a photo folder here", "or press ⌘O"])
        #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.open"])
        #expect(hint.accessibilityRole() == .staticText)
        #expect(hint.accessibilityLabel() == "or press ⌘O")
        #expect(hint.accessibilityPerformPress() == false)
        #expect(hint.isAccessibilityFocused() == false)
        #expect(!hint.acceptsFirstResponder && !hint.canBecomeKeyView)
        #expect(!hint.isEditable && !hint.isSelectable)
        let hintFrame = hint.accessibilityFrame(), buttonFrame = button.accessibilityFrame()
        #expect(hintFrame.width > 0 && hintFrame.height > 0)
        if width == 960 {
            #expect(abs(hintFrame.minX - buttonFrame.maxX - 12) <= 2)
            #expect(abs(hintFrame.midY - buttonFrame.midY) <= 2)
        } else {
            #expect(abs(hintFrame.minX - buttonFrame.maxX - 12) <= 2)
            #expect(abs(hintFrame.midY - buttonFrame.midY) <= 2)
        }
        let local = scene.content.convert(hint.bounds, from: hint)
        let screen = scene.window.convertToScreen(scene.content.convert(local, to: nil))
        #expect(abs(screen.minY - hintFrame.minY) <= 2 && abs(screen.maxY - hintFrame.maxY) <= 2)
        #expect(scene.content.bounds.contains(local))
        #expect(try inputHintVisibleInk(scene.content, in: local) > 10)
        print("inputHint geometry", width, hintFrame, "button", buttonFrame)
        #expect(scene.window.makeFirstResponder(scene.canvas))
        let moreTool = scene.chrome.tools[2]  // #444: 侧栏 and 返回网格 are disabled with no folder; 更多 is first in the loop.
        for target: NSView in [button, moreTool, scene.canvas] {
            scene.window.selectNextKeyView(nil)
            #expect(scene.window.firstResponder === target)
        }
        #expect(scene.canvas.nextValidKeyView === button)
        #expect(nodes.filter { $0.accessibilityIdentifier() == "first-launch.shortcut" }.count == 1)
    }
}

@Test @MainActor func inputHintOnlyEmptyAcrossStateTransitionsWithoutDuplicates() throws {
    let scene = StatesScene()
    defer { scene.session.closeImage(); scene.window.close() }
    scene.window.setFrameOrigin(NSPoint(x: -20000, y: -20000)); scene.window.orderFront(nil)
    let rows: [(ViewerImageStatus, [String], [String])] = [
        (.empty, ["Drop a photo folder here", "or press ⌘O"], ["state.open"]),
        (.loading("B.png"), ["Opening B.png…"], ["state.cancel"]),
        (.failed(.corruptImage, "B.png"), ["Unable to read this image", "B.png", "The file may be damaged or its format unreadable."], ["state.retry", "state.next"]),
        (.detailLimited, ["Showing reduced detail"], []), (.showing, [], []),
        (.empty, ["Drop a photo folder here", "or press ⌘O"], ["state.open"])
    ]
    for (status, lines, buttons) in rows {
        scene.state.display(status, nextEnabled: true)
        scene.content.layoutSubtreeIfNeeded(); scene.content.displayIfNeeded()
        #expect(scene.state.textLines == lines)
        #expect(scene.state.buttons.compactMap { $0.identifier?.rawValue } == buttons)
        let hints = inputHintViews(scene.state).filter { $0.accessibilityIdentifier() == "first-launch.shortcut" }
        #expect(hints.count == (status == .empty ? 1 : 0))
        #expect(scene.state.isHidden == (status == .showing))
    }
}
