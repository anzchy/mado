import AppKit
import Testing
import MadoApplication
import MadoMacUI

@Suite(.timeLimit(.minutes(3))) struct AccessRebindRenderedContract {
@MainActor @Test(arguments: [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)])
func t231NotFoundUsesPage26TwoButtonRenderedFrames(_ size: NSSize) throws {
    _ = NSApplication.shared
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = LostAccessStateView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view; view.appearance = NSAppearance(named: appearance)
        view.display(cause: .notFound, text: .init(title: "找不到", detail: "Mado 无法找到此文件夹。请在新位置选择，或选择其他文件夹。", waiting: "", reselect: "在新位置选择…", chooseOther: "选择其他文件夹…"))
        view.layoutSubtreeIfNeeded()
        #expect(view.iconView.frame.size == NSSize(width: 32, height: 32))
        #expect(view.iconView.frame.minY - view.titleLabel.frame.maxY == 18)
        #expect(view.titleLabel.frame.minY - view.detailLabel.frame.maxY == 9)
        #expect(view.detailLabel.frame.minY - view.reselectButton.frame.maxY == 18)
        #expect(view.chooseOtherButton.frame.minX - view.reselectButton.frame.maxX == 16)
        #expect(view.detailLabel.frame.width == 460)
        #expect(view.titleLabel.font == NSFont.systemFont(ofSize: 16, weight: .medium))
        #expect(view.buttons.count == 2 && view.waitingLabel.superview == nil)
    }
}

@MainActor @Test(arguments: [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)])
func t231RebindStripFramesAccessibilityAndKeyboard(_ size: NSSize) throws {
    _ = NSApplication.shared
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AccessRebindStripView(frame: NSRect(x: 0, y: 0, width: size.width, height: 44))
        window.contentView?.addSubview(view); view.appearance = NSAppearance(named: appearance)
        view.messageLabel.stringValue = "已更新到 /" + String(repeating: "very-long-location/", count: 30)
        view.layoutSubtreeIfNeeded()
        #expect(view.messageLabel.lineBreakMode == .byTruncatingMiddle)
        #expect(view.messageLabel.maximumNumberOfLines == 1)
        #expect(view.undoButton.frame.height == 28 && view.closeButton.frame.size == NSSize(width: 28, height: 28))
        #expect(view.messageLabel.frame.maxX + 8 <= view.undoButton.frame.minX)
        #expect(view.undoButton.frame.maxX + 8 <= view.closeButton.frame.minX)
        #expect(view.closeButton.frame.maxX <= view.bounds.maxX - 16)
        #expect(view.closeButton.accessibilityLabel() == String(localized: "Dismiss Location Update"))
        #expect(view.undoButton.canBecomeKeyView && view.closeButton.canBecomeKeyView)
    }
}

}

@Test(.timeLimit(.minutes(3))) func t231NotFoundCatalogTranslationsAreExact() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Resources/Localizable.xcstrings")
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    let strings = try #require(object["strings"] as? [String: [String: Any]])
    for (key, chinese) in [("Not Found", "找不到"), ("Choose at New Location…", "在新位置选择…"), ("Updated to %@", "已更新到 %@"), ("Dismiss Location Update", "关闭位置更新提示")] {
        let locales = try #require(strings[key]?["localizations"] as? [String: [String: Any]])
        #expect((locales["en"]?["stringUnit"] as? [String: String])?["value"] == key)
        #expect((locales["zh-Hans"]?["stringUnit"] as? [String: String])?["value"] == chinese)
    }
}
