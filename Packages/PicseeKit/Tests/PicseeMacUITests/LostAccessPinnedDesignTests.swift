import AppKit
import CryptoKit
import Testing
import PicseeApplication
@testable import PicseeMacUI

private struct LostAccessCase: Sendable, CustomTestStringConvertible {
    let width: Int
    let height: Int
    let dark: Bool
    let chinese: Bool
    let disk: Bool
    var testDescription: String { "\(width)x\(height)-\(dark ? "dark" : "light")-\(chinese ? "zh" : "en")-\(disk ? "disk" : "unknown")" }
    static let all = [(1280, 800), (1019, 853), (800, 680)].flatMap { width, height in
        [false, true].flatMap { dark in [false, true].flatMap { chinese in
            [false, true].map { disk in Self(width: width, height: height, dark: dark, chinese: chinese, disk: disk) }
        } }
    }
    var text: LostAccessStateText {
        if chinese {
            return .init(title: disk ? "外接磁盘“T7”未连接" : "无法访问此文件夹",
                detail: disk ? "“待整理的旅行照片”在外接磁盘上。\n连接磁盘后，picsee 会重新确认访问权限，然后自动恢复。" : "picsee 现在读不到“待整理的旅行照片”。重新选择这个文件夹，或换一个文件夹继续。",
                waiting: "等待磁盘连接…", reselect: "重新选择文件夹…", chooseOther: "选择其他文件夹…")
        }
        return .init(title: disk ? "External Disk “T7” Is Not Connected" : "Unable to Access This Folder",
            detail: disk ? "“Travel photos to organize” is on an external disk.\nConnect the disk and picsee will verify access before restoring your place." : "picsee can’t read “Travel photos to organize” right now. Choose this folder again, or choose another folder to continue.",
            waiting: "Waiting for the disk…", reselect: "Choose Folder Again…", chooseOther: "Choose Another Folder…")
    }
}

@MainActor private func lostAccessColor(_ color: NSColor, equals expected: PinnedDesign.Color) throws {
    let rgb = try #require(color.usingColorSpace(.sRGB))
    #expect(abs(rgb.redComponent - expected.red) < 0.01)
    #expect(abs(rgb.greenComponent - expected.green) < 0.01)
    #expect(abs(rgb.blueComponent - expected.blue) < 0.01)
}

private let lostAccessPinnedPageSHA256 = "9f7f345bec6a5ac12548ea0c419acc9d939cc40ac35b4d5b762935efbcf86f62"

private func lostAccessManifestEntryRemainsExact(_ data: Data) throws -> Bool {
    let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let entries = manifest?["states"] as? [[String: Any]]
    guard let entry = entries?.first(where: { $0["name"] as? String == "permission-denied" }) else {
        return false
    }
    let expected: [String: Any] = [
        "name": "permission-denied", "title": "26 目录权限失效",
        "file": "permission-denied.html", "sha256": lostAccessPinnedPageSHA256,
        "viewport": ["width": 1280, "height": 800],
        "kind": "static-mockup", "origin": "local-C-adaptation"
    ]
    return NSDictionary(dictionary: entry).isEqual(to: expected)
}

@Test private func t320LostAccessManifestEntryFixtures() throws {
    let page: [String: Any] = [
        "name": "permission-denied", "title": "26 目录权限失效",
        "file": "permission-denied.html", "sha256": lostAccessPinnedPageSHA256,
        "viewport": ["width": 1280, "height": 800],
        "kind": "static-mockup", "origin": "local-C-adaptation"
    ]
    let unrelated = ["name": "grid-light", "file": "grid-light.html", "sha256": "old-hash"]
    let repinned = ["name": "grid-light", "file": "repinned-grid.html", "sha256": "new-hash"]
    func manifest(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["states": entries])
    }
    let baseline = try lostAccessManifestEntryRemainsExact(manifest([unrelated, page]))
    #expect(baseline)
    for entries in [[repinned, page], [page, repinned], [page]] {
        let accepted = try lostAccessManifestEntryRemainsExact(manifest(entries))
        #expect(accepted)
        #expect(accepted == baseline)
    }
    let mutations: [(String, Any)] = [
        ("name", "another-page"), ("file", "another-page.html"), ("sha256", "changed-hash"),
        ("title", "Changed title"), ("kind", "interactive"), ("origin", "changed-origin"),
        ("viewport", ["width": 1279, "height": 800]),
        ("viewport", ["width": 1280, "height": 799])
    ]
    for (field, value) in mutations {
        var changed = page
        changed[field] = value
        #expect(try !lostAccessManifestEntryRemainsExact(manifest([unrelated, changed])))
    }
    #expect(try !lostAccessManifestEntryRemainsExact(manifest([])))
    #expect(try !lostAccessManifestEntryRemainsExact(manifest([unrelated])))
}

@Test @MainActor private func t229LostAccessPinnedSourceRemainsExact() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL
    let directory = root.appendingPathComponent("design/prototypes/picsee-browser/states")
    let page = try Data(contentsOf: directory.appendingPathComponent("permission-denied.html"))
    #expect(SHA256.hash(data: page).map { String(format: "%02x", $0) }.joined() == "9f7f345bec6a5ac12548ea0c419acc9d939cc40ac35b4d5b762935efbcf86f62")
    let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    #expect(try lostAccessManifestEntryRemainsExact(manifest))
}

@Test(arguments: LostAccessCase.all) @MainActor private func t229LostAccessPinnedNativeComposition(_ sample: LostAccessCase) throws {
    _ = NSApplication.shared
    let size = NSSize(width: CGFloat(sample.width), height: CGFloat(sample.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: sample.dark ? .darkAqua : .aqua)
    let shell = GridShellView(frame: NSRect(origin: .zero, size: size), preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    let view = LostAccessStateView(frame: shell.mainContent.bounds)
    view.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(view)
    view.display(cause: sample.disk ? .diskNotConnected : .unknown, text: sample.text)
    view.layoutSubtreeIfNeeded()
    let page = try PinnedDesign.page("permission-denied")
    let viewport = Double(sample.width)
    #expect(view.accessibilityIdentifier() == "access.lost.state")
    #expect(view.iconView.superview === view)
    #expect(view.iconView.image != nil)
    #expect(view.iconView.frame.size == NSSize(width: 32, height: 32))
    #expect(view.titleLabel.stringValue == sample.text.title)
    #expect(view.detailLabel.stringValue == sample.text.detail)
    #expect(view.titleLabel.font?.pointSize == CGFloat(try page.length(".empty-state h2", "font-size", viewport: viewport)))
    #expect(view.titleLabel.font == NSFont.systemFont(ofSize: 16, weight: .medium))
    #expect(view.detailLabel.font?.pointSize == CGFloat(try page.length(".empty-state p", "font-size", viewport: viewport)))
    #expect(abs(view.iconView.frame.minY - view.titleLabel.frame.maxY - (try page.length(".empty-state h2", "margin-top", viewport: viewport))) < 0.5)
    #expect(abs(view.titleLabel.frame.minY - view.detailLabel.frame.maxY - (try page.length(".empty-state p", "margin-top", viewport: viewport))) < 0.5)
    #expect(view.detailLabel.frame.width <= (try page.length(".recovery-state p", "max-width", viewport: viewport)))
    let detailSize = view.detailLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: view.detailLabel.frame.width, height: 10_000)) ?? .zero
    #expect(view.detailLabel.frame.height + 0.5 >= detailSize.height)
    #expect(view.detailLabel.maximumNumberOfLines == 0)
    try #require(view.detailLabel.attributedStringValue.length > 0)
    let paragraph = try #require(view.detailLabel.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(abs(paragraph.minimumLineHeight - (try page.lineHeight(".empty-state p", viewport: viewport))) < 0.01)
    #expect(abs(paragraph.maximumLineHeight - (try page.lineHeight(".empty-state p", viewport: viewport))) < 0.01)
    #expect(view.buttons.count == (sample.disk ? 1 : 2))
    #expect(view.mainButton === (sample.disk ? view.chooseOtherButton : view.reselectButton))
    let rowViews: [NSView] = sample.disk ? [view.waitingDot, view.waitingLabel, view.chooseOtherButton] : view.buttons
    let actionFrame = rowViews.reduce(NSRect.null) { $0.union($1.frame) }
    #expect(abs(view.detailLabel.frame.minY - actionFrame.maxY - (try page.length(".mock-actions", "margin-top", viewport: viewport))) < 0.5)
    let content: [NSView] = [view.iconView, view.titleLabel, view.detailLabel] + rowViews
    let union = content.reduce(NSRect.null) { $0.union($1.frame) }
    #expect(abs(union.midX - view.bounds.midX) < 0.5)
    // Native grid scroll content: top16/bottom30, then recovery top24/bottom48.
    #expect(abs(union.midY - (view.bounds.midY + 19)) < 0.5)
    for child in content {
        #expect(child.superview === view && !child.isHiddenOrHasHiddenAncestor)
        #expect(child.frame.width > 0 && child.frame.height > 0)
        #expect(view.bounds.insetBy(dx: 16, dy: 16).contains(child.frame))
    }
    #expect(view.chooseOtherButton.title == sample.text.chooseOther)
    #expect(view.chooseOtherButton.font?.pointSize == 13)
    #expect(view.chooseOtherButton.accessibilityIdentifier() == "access.lost.chooseOther")
    for button in view.buttons {
        let textWidth = (button.title as NSString).size(withAttributes: [.font: try #require(button.font)]).width
        #expect(button.frame.width >= textWidth + (button === view.reselectButton ? 32 : 8) - 0.5)
        #expect(button.frame.height >= (button.font?.ascender ?? 0) - (button.font?.descender ?? 0) + 16 - 0.5)
    }
    if sample.disk {
        #expect(view.waitingLabel.stringValue == sample.text.waiting)
        #expect(view.waitingLabel.font?.pointSize == 12)
        #expect(view.waitingDot.frame.size == NSSize(width: 7, height: 7))
        #expect(abs(view.waitingLabel.frame.minX - view.waitingDot.frame.maxX - 6) < 0.5)
        #expect(abs(view.chooseOtherButton.frame.minX - view.waitingLabel.frame.maxX - 16) < 0.5)
        #expect(view.reselectButton.superview == nil)
    } else {
        #expect(view.reselectButton.title == sample.text.reselect)
        #expect(view.reselectButton.accessibilityIdentifier() == "access.lost.reselect")
        #expect(abs(view.chooseOtherButton.frame.minX - view.reselectButton.frame.maxX - 16) < 0.5)
        #expect(view.waitingLabel.superview == nil && view.waitingDot.superview == nil)
        #expect(view.reselectButton.layer?.cornerRadius == 6)
    }
    var appearanceError: Error?
    window.appearance?.performAsCurrentDrawingAppearance {
        do {
        let theme = sample.dark ? ".theme-dark" : ".theme-light"
        try lostAccessColor(try #require(view.titleLabel.textColor), equals: page.color(theme, "--color-text", viewport: viewport))
        try lostAccessColor(try #require(view.detailLabel.textColor), equals: page.color(theme, "--color-muted", viewport: viewport))
        if sample.disk {
            try lostAccessColor(NSColor(cgColor: try #require(view.waitingDot.layer?.backgroundColor)) ?? .clear,
                equals: page.color(":root", "--color-banner-unsaved", viewport: viewport))
        } else {
            try lostAccessColor(NSColor(cgColor: try #require(view.reselectButton.layer?.backgroundColor)) ?? .clear,
                equals: page.color(theme, "--color-accent-fill", viewport: viewport))
        }
        } catch { appearanceError = error }
    }
    if let appearanceError { throw appearanceError }
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
}

@Test @MainActor private func t229LostAccessActionsUseNativeFocusAndRetireOldControls() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    var reselect = 0
    var other = 0
    view.onReselectFolder = { reselect += 1 }
    view.onChooseAnotherFolder = { other += 1 }
    view.display(cause: .unknown, text: LostAccessCase.all[0].text)
    view.layoutSubtreeIfNeeded()
    #expect(view.buttons == [view.reselectButton, view.chooseOtherButton])
    #expect(window.makeFirstResponder(view.reselectButton))
    #expect(window.firstResponder === view.reselectButton)
    #expect(view.reselectButton.nextValidKeyView === view.chooseOtherButton)
    #expect(view.reselectButton.focusRingType == .exterior)
    view.reselectButton.performClick(nil)
    view.chooseOtherButton.performClick(nil)
    #expect(reselect == 1 && other == 1)
    let retired = view.reselectButton
    view.display(cause: .diskNotConnected, text: LostAccessCase.all[1].text)
    view.layoutSubtreeIfNeeded()
    #expect(view.buttons == [view.chooseOtherButton])
    #expect(retired.superview == nil && !retired.isEnabled)
    #expect(window.firstResponder !== retired)
    retired.performClick(nil)
    #expect(reselect == 1)
    #expect(window.makeFirstResponder(view.chooseOtherButton))
    #expect(view.chooseOtherButton.focusRingType == .exterior)
}
