import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

/// #238 (P3-17c D3): native 「读取失败」 against folder-loading.html `?case=failed` (24F-A).
private struct ReadFailedCase: Sendable, CustomTestStringConvertible {
    let width: Int
    let height: Int
    let dark: Bool
    var testDescription: String { "\(width)x\(height)-\(dark ? "dark" : "light")" }
    static let all = [(1280, 800), (1019, 853), (800, 680)].flatMap { width, height in
        [false, true].map { Self(width: width, height: height, dark: $0) }
    }
}

/// The pinned zh-Hans copy (24F-A, #236 owner choice).
private let readFailedChinese = ReadFailedStateText(title: "没能读完“待整理”",
    detail: "读取在中途停止了。为避免显示不完整的列表，已经找到的图片暂不显示。", retry: "重试", chooseOther: "选择其他文件夹…")

@MainActor private func readFailedColor(_ color: NSColor, equals expected: PinnedDesign.Color, _ what: String) throws {
    let rgb = try #require(color.usingColorSpace(.sRGB))
    #expect(abs(rgb.redComponent - expected.red) < 0.01, "\(what)")
    #expect(abs(rgb.greenComponent - expected.green) < 0.01, "\(what)")
    #expect(abs(rgb.blueComponent - expected.blue) < 0.01, "\(what)")
}

@Test(arguments: ReadFailedCase.all) @MainActor private func readFailedPinnedNativeComposition(_ sample: ReadFailedCase) throws {
    _ = NSApplication.shared
    let size = NSSize(width: CGFloat(sample.width), height: CGFloat(sample.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: sample.dark ? .darkAqua : .aqua)
    let shell = GridShellView(frame: NSRect(origin: .zero, size: size), preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    let view = ReadFailedStateView(frame: shell.mainContent.bounds)
    view.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(view)
    view.display(readFailedChinese)
    view.layoutSubtreeIfNeeded()
    let page = try PinnedDesign.page("folder-loading")
    let viewport = Double(sample.width)
    #expect(view.titleLabel.stringValue == "没能读完“待整理”")
    #expect(view.titleLabel.stringValue.unicodeScalars.contains("\u{201C}") && view.titleLabel.stringValue.unicodeScalars.contains("\u{201D}"))
    #expect(view.detailLabel.stringValue == readFailedChinese.detail)
    #expect(view.buttons.map(\.title) == ["重试", "选择其他文件夹…"])
    #expect(view.iconView.image != nil && view.iconView.image?.isTemplate == true)
    #expect(view.iconView.frame.size == NSSize(width: 32, height: 32))
    #expect(view.titleLabel.font == NSFont.systemFont(ofSize: 16, weight: .medium))
    #expect(view.titleLabel.font?.pointSize == CGFloat(try page.length(".empty-state h2", "font-size", viewport: viewport)))
    #expect(view.detailLabel.font?.pointSize == CGFloat(try page.length(".empty-state p", "font-size", viewport: viewport)))
    #expect(abs(view.iconView.frame.minY - view.titleLabel.frame.maxY - (try page.length(".empty-state h2", "margin-top", viewport: viewport))) < 0.5)
    #expect(abs(view.titleLabel.frame.minY - view.detailLabel.frame.maxY - (try page.length(".empty-state p", "margin-top", viewport: viewport))) < 0.5)
    #expect(view.detailLabel.frame.width <= (try page.length(".failed-state p", "max-width", viewport: viewport)))
    #expect(view.detailLabel.maximumNumberOfLines == 0)
    try #require(view.detailLabel.attributedStringValue.length > 0)
    let paragraph = try #require(view.detailLabel.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(abs(paragraph.minimumLineHeight - (try page.lineHeight(".empty-state p", viewport: viewport))) < 0.01)
    let actions = view.buttons.reduce(NSRect.null) { $0.union($1.frame) }
    #expect(abs(view.detailLabel.frame.minY - actions.maxY - (try page.length(".mock-actions", "margin-top", viewport: viewport))) < 0.5)
    #expect(abs(view.chooseOtherButton.frame.minX - view.retryButton.frame.maxX - (try page.length(".mock-actions", "gap", viewport: viewport))) < 0.5)
    #expect(view.retryButton.layer?.cornerRadius == CGFloat(try page.lengthValue("var(--radius-control)", viewport: viewport)))
    let font = try #require(view.retryButton.font)
    #expect(font.pointSize == 13 && view.chooseOtherButton.font?.pointSize == 13)
    let retryText = ceil((view.retryButton.title as NSString).size(withAttributes: [.font: font]).width)
    #expect(abs(view.retryButton.frame.width - (retryText + 32)) < 1)
    #expect(abs(view.retryButton.frame.height - (ceil(font.ascender - font.descender) + 16)) < 1)
    let content: [NSView] = [view.iconView, view.titleLabel, view.detailLabel] + view.buttons
    let union = content.reduce(NSRect.null) { $0.union($1.frame) }
    #expect(abs(union.midX - view.bounds.midX) < 0.5)
    // `.failed-state` padding-bottom (content-padding 40 + 2 × radius-inner 4 = 48) in the grid scroll (16 / 30), as page 26.
    #expect(abs(union.midY - (view.bounds.midY + 19)) < 0.5)
    for child in content {
        #expect(child.superview === view && !child.isHiddenOrHasHiddenAncestor)
        #expect(view.bounds.insetBy(dx: 16, dy: 16).contains(child.frame))
    }
    var appearanceError: Error?
    window.appearance?.performAsCurrentDrawingAppearance {
        do {
            let theme = sample.dark ? ".theme-dark" : ".theme-light"
            try readFailedColor(try #require(view.titleLabel.textColor), equals: page.color(theme, "--color-text", viewport: viewport), "title")
            try readFailedColor(try #require(view.detailLabel.textColor), equals: page.color(theme, "--color-muted", viewport: viewport), "detail")
            try readFailedColor(try #require(view.iconView.contentTintColor), equals: page.color(theme, "--color-muted", viewport: viewport), "icon")
            try readFailedColor(NSColor(cgColor: try #require(view.retryButton.layer?.backgroundColor)) ?? .clear,
                equals: page.color(theme, "--color-accent-fill", viewport: viewport), "primary fill")
            let primaryTitle = view.retryButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            try readFailedColor(try #require(primaryTitle), equals: page.color(":root", "--color-on-accent", viewport: viewport), "primary title")
            let textTitle = view.chooseOtherButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(textTitle == DesignColor.selectionText.nsColor, "text button title")
            #expect(view.chooseOtherButton.layer?.backgroundColor == nil || NSColor(cgColor: view.chooseOtherButton.layer!.backgroundColor!)?.alphaComponent == 0)
            #expect(!view.chooseOtherButton.isBordered && !view.retryButton.isBordered)
        } catch { appearanceError = error }
    }
    if let appearanceError { throw appearanceError }
}

@Test @MainActor func readFailedRetryIsInitialKeyViewWithAXLabels() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ReadFailedStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    var retries = 0, others = 0
    view.onRetry = { retries += 1 }; view.onChooseOtherFolder = { others += 1 }
    view.display(readFailedChinese)
    view.layoutSubtreeIfNeeded()
    #expect(view.buttons.first === view.retryButton)
    #expect(window.makeFirstResponder(view.buttons.first))
    #expect(window.firstResponder === view.retryButton)
    #expect(view.retryButton.nextValidKeyView === view.chooseOtherButton)
    #expect(view.retryButton.focusRingType == .exterior)
    #expect(view.retryButton.identifier?.rawValue == "state.retry-folder")
    #expect(view.chooseOtherButton.identifier?.rawValue == "state.choose-other-folder")
    #expect(view.accessibilityLabel() == readFailedChinese.title)
    #expect(view.accessibilityValue() as? String == readFailedChinese.detail)
    #expect(view.retryButton.accessibilityLabel() == "重试" && view.chooseOtherButton.accessibilityLabel() == "选择其他文件夹…")
    let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
    #expect(children.contains { $0 === view.titleLabel } && children.contains { $0 === view.detailLabel })
    let order = view.subviews
    #expect((order.firstIndex { $0 === view.retryButton } ?? .max) < (order.firstIndex { $0 === view.chooseOtherButton } ?? .min))
    view.retryButton.performClick(nil); view.chooseOtherButton.performClick(nil)
    #expect(retries == 1 && others == 1)
}

// MARK: The state host switches `.folderScanFailed` to 24F-A.

private actor ReadFailedNativeLeases: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease { AccessLease(url: URL(fileURLWithPath: "/native-folder"), rootID: nil) }
    func release(_ lease: AccessLease) { }
}
/// Fails its first `failures` scans after one image, then lists the folder.
private actor ReadFailedNativeScanner: FolderScanning {
    private(set) var calls = 0
    let failures: Int
    init(failures: Int = 1) { self.failures = failures }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        calls += 1
        try await emit([FolderEntry(url: folder.appendingPathComponent("a1.png"), root: root)])
        if calls <= failures { throw CocoaError(.fileReadUnknown) }
    }
}

@MainActor private func readFailedHostScene(failures: Int = 1)
    async -> (StatesScene, FolderScanCoordinator, ReadFailedNativeScanner) {
    let scene = StatesScene(), scanner = ReadFailedNativeScanner(failures: failures)
    let coordinator = FolderScanCoordinator(access: ReadFailedNativeLeases(), scanner: scanner)
    scene.session.folderScan = coordinator
    scene.state.surface = .gridReading
    _ = try? await coordinator.begin(folder: URL(fileURLWithPath: "/native-folder/待整理"), rootID: AccessRootID()).value
    scene.state.refresh()
    return (scene, coordinator, scanner)
}

@MainActor private func readFailedStrings(_ view: NSView) -> [String] {
    var strings: [String] = []
    if let field = view as? NSTextField { strings.append(field.stringValue) }
    if let button = view as? NSButton { strings.append(button.title) }
    if let label = view.accessibilityLabel() { strings.append(label) }
    return strings + view.subviews.filter { !$0.isHidden }.flatMap(readFailedStrings)
}

/// #316 M2: a Session change releases the pre-scan hold without leaving the reading surface.
@Test @MainActor func i316SessionStatusChangeReleasesHeldReading() async throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    let coordinator = FolderScanCoordinator(access: ReadFailedNativeLeases(), scanner: ReadFailedNativeScanner())
    scene.session.folderScan = coordinator
    scene.session.enterFolderGrid(items: [], sourceVersion: .init(0))
    scene.state.surface = .gridReading
    scene.state.display(.readingFolder)
    scene.state.refresh()
    #expect(scene.session.imageStatus == .empty)
    #expect(scene.state.textLines.first == "Reading Folder…")
    _ = try? await coordinator.begin(folder: URL(fileURLWithPath: "/native-folder/待整理"), rootID: AccessRootID()).value
    scene.state.refresh()
    #expect(scene.state.surface == .gridReading)
    #expect(scene.session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    let failure = try #require(scene.state.readFailedView)
    #expect(!failure.isHiddenOrHasHiddenAncestor)
    #expect(scene.state.textLines.first == "Couldn't finish reading “待整理”")
    scene.session.folderScan = nil
    scene.state.refresh()
    #expect(scene.state.surface == .gridReading)
    #expect(scene.state.subviews.contains { $0 is FirstLaunchView }, "a later empty Session is not masked by the old hold")
}

@Test @MainActor func readFailedHostShowsPinnedStateWithoutPartialCount() async throws {
    let (scene, _, _) = await readFailedHostScene()
    defer { scene.window.close() }
    #expect(scene.session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    let view = try #require(scene.state.readFailedView)
    #expect(view.superview === scene.state && !view.isHiddenOrHasHiddenAncestor)
    #expect(view.frame == scene.state.bounds)
    #expect(view.titleLabel.stringValue == "Couldn't finish reading “待整理”")
    #expect(view.detailLabel.stringValue == "Reading stopped partway. To avoid showing an incomplete list, the images found so far are hidden.")
    #expect(scene.state.textLines == [view.titleLabel.stringValue, view.detailLabel.stringValue])
    #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.retry-folder", "state.choose-other-folder"])
    #expect(scene.state.buttons.map(\.title) == ["Retry", "Choose Another Folder…"])
    let strings = readFailedStrings(scene.state)
    #expect(!strings.contains { $0.contains("Images found before scan stopped") || $0.contains("Unable to finish reading folder") })
    #expect(!strings.contains { $0.contains { $0.isNumber } })
    #expect((scene.state.accessibilityChildren() ?? []).compactMap { $0 as? NSView }.contains { $0 === view })
}

@Test @MainActor func readFailedRetryButtonStartsRescan() async throws {
    let (scene, coordinator, scanner) = await readFailedHostScene(failures: 2)
    defer { scene.window.close() }
    let retry = try #require(scene.state.buttons.first { $0.identifier?.rawValue == "state.retry-folder" })
    retry.performClick(nil)
    try await waitUntil { await scanner.calls >= 2 && !coordinator.isScanning }
    #expect(await scanner.calls == 2)
    scene.state.refresh()
    // The retry failed again: 24F-A is back, with fresh, enabled controls.
    #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.retry-folder", "state.choose-other-folder"])
    #expect(scene.state.buttons.allSatisfy { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor })
}

@Test @MainActor func readFailedChooseOtherFolderRequestsOpen() async throws {
    let (scene, coordinator, scanner) = await readFailedHostScene()
    defer { scene.window.close() }
    let other = try #require(scene.state.buttons.first { $0.identifier?.rawValue == "state.choose-other-folder" })
    other.performClick(nil)
    #expect(scene.host.opens == 1)
    #expect(await scanner.calls == 1 && coordinator.failure != nil)
}

@Test @MainActor func readFailedHostSwitchTransitions() async throws {
    let (scene, _, _) = await readFailedHostScene()
    defer { scene.window.close() }
    func count() -> Int { scene.state.subviews.filter { $0 is ReadFailedStateView && !$0.isHidden }.count }
    #expect(count() == 1)
    scene.state.display(.readingFolder)
    #expect(count() == 0 && scene.state.buttons.map { $0.identifier?.rawValue } == ["state.cancel-folder"])
    scene.state.display(.folderScanFailed("Folder scan failed", "B"))
    #expect(count() == 1 && scene.state.readFailedView?.titleLabel.stringValue == "Couldn't finish reading “B”")
    scene.state.display(.failed(.corruptImage, "x.png"))
    #expect(count() == 0)
    #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.retry"])
}

@Test func readFailedCatalogKeysHaveEnglishAndChinese() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    for (key, chinese) in [("Couldn't finish reading “%@”", "没能读完“%@”"),
        ("Reading stopped partway. To avoid showing an incomplete list, the images found so far are hidden.",
         "读取在中途停止了。为避免显示不完整的列表，已经找到的图片暂不显示。"),
        ("Read incomplete", "读取未完成"), ("Retry", "重试"), ("Choose Another Folder…", "选择其他文件夹…"),
        ("Unable to finish reading folder", "无法完成文件夹读取"),
        ("Images found before scan stopped: %lld", "扫描停止前找到图片：%lld 张")] {
        let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
        for (language, expected) in [("en", key), ("zh-Hans", chinese)] {
            let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(unit?["value"] as? String == expected, "\(key) \(language)")
        }
    }
}
