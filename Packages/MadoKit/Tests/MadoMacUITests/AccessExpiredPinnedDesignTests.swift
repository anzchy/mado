import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

private struct ExpiredDesignSample: Sendable {
    let width: Int
    let dark: Bool
    let chinese: Bool
    let expired: Bool
    static let all = [800, 1280].flatMap { width in
        [false, true].flatMap { dark in [false, true].flatMap { chinese in
            [false, true].map { Self(width: width, dark: dark, chinese: chinese, expired: $0) }
        } }
    }
    var text: LostAccessStateText {
        if chinese {
            return .init(title: expired ? "授权失效" : "无法访问此文件夹",
                detail: expired ? "访问权限已失效。重新选择这个文件夹即可恢复，Mado 会回到你刚才的位置。" : "Mado 现在读不到“待整理的旅行照片”。重新选择这个文件夹，或换一个文件夹继续。",
                waiting: "等待磁盘连接…", reselect: "重新选择文件夹…", chooseOther: "选择其他文件夹…")
        }
        return .init(title: expired ? "Access Has Expired" : "Unable to Access This Folder",
            detail: expired ? "Access has expired. Choose this folder again to restore access; Mado will return to where you left off." : "Mado can’t read “Travel photos to organize” right now. Choose this folder again, or choose another folder to continue.",
            waiting: "Waiting for the disk…", reselect: "Choose Folder Again…", chooseOther: "Choose Another Folder…")
    }
}

// Layout rules from permission-denied.html; brief AC-4 and approved amendment
// override the default HTML title/action count for the accessExpired case.
@Test(.timeLimit(.minutes(2)), arguments: ExpiredDesignSample.all) @MainActor
private func t230AccessExpiredAndUnknownPinnedFrames(_ sample: ExpiredDesignSample) throws {
    _ = NSApplication.shared
    let size = NSSize(width: sample.width, height: sample.width == 800 ? 680 : 800)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: sample.dark ? .darkAqua : .aqua)
    let shell = GridShellView(frame: NSRect(origin: .zero, size: size), preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    let view = LostAccessStateView(frame: shell.mainContent.bounds)
    shell.mainContent.addSubview(view)
    view.display(cause: sample.expired ? .accessExpired : .unknown, text: sample.text)
    view.layoutSubtreeIfNeeded()
    let page = try PinnedDesign.page("permission-denied"), viewport = Double(sample.width)
    #expect(view.buttons == (sample.expired ? [view.reselectButton] : [view.reselectButton, view.chooseOtherButton]))
    #expect(view.titleLabel.stringValue == sample.text.title && view.detailLabel.stringValue == sample.text.detail)
    #expect(view.titleLabel.font?.pointSize == CGFloat(try page.length(".empty-state h2", "font-size", viewport: viewport)))
    #expect(view.detailLabel.font?.pointSize == CGFloat(try page.length(".empty-state p", "font-size", viewport: viewport)))
    #expect(abs(view.iconView.frame.minY - view.titleLabel.frame.maxY - (try page.length(".empty-state h2", "margin-top", viewport: viewport))) < 0.5)
    #expect(abs(view.titleLabel.frame.minY - view.detailLabel.frame.maxY - (try page.length(".empty-state p", "margin-top", viewport: viewport))) < 0.5)
    #expect(view.detailLabel.frame.width <= (try page.length(".recovery-state p", "max-width", viewport: viewport)))
    let row = view.buttons.reduce(NSRect.null) { $0.union($1.frame) }
    #expect(abs(row.midX - view.bounds.midX) < 0.5)
    #expect(abs(view.detailLabel.frame.minY - row.maxY - (try page.length(".mock-actions", "margin-top", viewport: viewport))) < 0.5)
    if !sample.expired {
        #expect(abs(view.chooseOtherButton.frame.minX - view.reselectButton.frame.maxX - (try page.length(".mock-actions", "gap", viewport: viewport))) < 0.5)
    } else {
        #expect(view.chooseOtherButton.superview == nil && !view.chooseOtherButton.isEnabled)
    }
    let content: [NSView] = [view.iconView, view.titleLabel, view.detailLabel] + view.buttons
    let union = content.reduce(NSRect.null) { $0.union($1.frame) }
    #expect(abs(union.midY - (view.bounds.midY + 19)) < 0.5)
    for child in content { #expect(view.bounds.insetBy(dx: 16, dy: 16).contains(child.frame)) }
    for label in [view.titleLabel, view.detailLabel] {
        let required = try #require(label.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000))
        #expect(label.frame.height + 0.5 >= required.height)
    }
    let paragraph = try #require(view.detailLabel.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(abs(paragraph.minimumLineHeight - (try page.lineHeight(".empty-state p", viewport: viewport))) < 0.01)
    for button in view.buttons {
        let font = try #require(button.font)
        #expect(button.frame.width >= (button.title as NSString).size(withAttributes: [.font: font]).width + (button === view.reselectButton ? 32 : 8) - 0.5)
    }
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
}

@Test(.timeLimit(.minutes(2))) @MainActor func t230CauseTransitionsRetireControlsAndMoveFocus() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    let text = ExpiredDesignSample.all[0].text
    var reselected = 0, other = 0
    view.onReselectFolder = { reselected += 1 }
    view.onChooseAnotherFolder = { other += 1 }
    view.display(cause: .unknown, text: text)
    #expect(window.makeFirstResponder(view.chooseOtherButton))
    view.display(cause: .accessExpired, text: text)
    #expect(view.buttons == [view.reselectButton])
    #expect(window.firstResponder === view.reselectButton)
    #expect(view.reselectButton.nextKeyView === view.reselectButton)
    #expect(view.chooseOtherButton.superview == nil && !view.chooseOtherButton.isEnabled)
    #expect(!(view.accessibilityChildren() ?? []).contains { ($0 as? NSView) === view.chooseOtherButton })
    view.chooseOtherButton.performClick(nil)
    view.reselectButton.performClick(nil)
    #expect(other == 0 && reselected == 1)
    view.display(cause: .diskNotConnected, text: text)
    #expect(window.firstResponder === view.chooseOtherButton)
    #expect(view.buttons == [view.chooseOtherButton])
    view.reselectButton.performClick(nil)
    #expect(reselected == 1)
    view.display(cause: .unknown, text: text)
    #expect(view.buttons == [view.reselectButton, view.chooseOtherButton])
    #expect(view.reselectButton.nextKeyView === view.chooseOtherButton)
    view.chooseOtherButton.performClick(nil)
    #expect(other == 1)
}
