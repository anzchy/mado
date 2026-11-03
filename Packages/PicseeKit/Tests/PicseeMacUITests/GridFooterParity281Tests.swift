import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
@testable import PicseeMacUI

@MainActor private func issue281FooterView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let match = issue281FooterView(id, in: child) { return match }
    }
    return nil
}

@MainActor private func issue281FooterScene(width: CGFloat, appearance: NSAppearance.Name = .aqua) throws -> (GridShellView, GridBrowserView, NSWindow) {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 772),
        preferencesStore: InMemoryDisplayPreferencesStore())
    shell.appearance = NSAppearance(named: appearance)
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    grid.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(grid)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
        styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = shell
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView(), shell: shell)
    let folder = URL(fileURLWithPath: "/tmp/picsee-grid-281-footer")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<12).map { index in
        let name = index == 1 ? String(repeating: "Long旅行FileName", count: 12) + ".jpg" : "DSC_034\(index).jpg"
        return FolderEntry(url: folder.appendingPathComponent(name), root: root)
    }
    let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    presentation.showCompletedGrid(snapshot, selection: BrowserSelection(),
        currentItemID: entries[1].itemID, offset: nil)
    shell.layoutSubtreeIfNeeded()
    return (shell, grid, window)
}

@Test @MainActor func issue281FooterLeftStatusAndSpaceHintMatchPinnedFrames() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let (shell, grid, window) = try issue281FooterScene(width: 1280, appearance: appearance)
        defer { window.close() }
        // grid-light.html: 30x30 filled toggle, 1px divider at x52, then current filename and count.
        #expect(shell.toggleButton.frame == NSRect(x: 12, y: 5, width: 30, height: 30))
        #expect(shell.toggleButton.layer?.backgroundColor != nil)
        #expect(Double(shell.toggleButton.layer?.cornerRadius ?? 0) == DesignMetrics.radii["control"]!)
        let divider = try #require(issue281FooterView("grid.footer.leading-divider", in: shell))
        #expect(divider.frame == NSRect(x: 52, y: 10, width: 1, height: 20))
        let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
        // Text boxes: an NSTextField draws 2pt inside its frame (name text at x 63, at most 240 wide).
        #expect(file.frame.minX == 61)
        #expect(file.frame.width <= 244)
        #expect(file.lineBreakMode == .byTruncatingTail)
        #expect(file.stringValue.hasPrefix("Long旅行FileName"))
        let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
        #expect(count.stringValue == "12 images")
        #expect(count.frame.minX - file.frame.maxX == 8, "12pt between the text boxes")
        let hint = try #require(issue281FooterView("grid.keyboard-hint", in: shell))
        #expect(!hint.isHidden)
        let design = try PinnedDesign.page(appearance == .darkAqua ? "grid-dark" : "grid-light")
        // .keyboard-hint>span margin-right + .grid-bottom-bar gap.
        let hintGap = try design.length(".keyboard-hint>span", "margin-right", viewport: 1280)
            + design.length(".grid-bottom-bar", "gap", viewport: 1280)
        #expect(abs(Double(shell.searchButton.frame.minX - hint.frame.maxX) - hintGap) < 0.01)
        #expect(hint.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue) == ["Space", "Quick Look"])

        let other = try #require(grid.displayedItemIDs.first)
        grid.activate(currentItemID: other)
        #expect(file.stringValue == "DSC_0340.jpg")
    }
}

@Test @MainActor func issue281SpaceHintUsesPinnedMaxWidthBreakpoint() throws {
    for (width, visible) in [(801.0, true), (800.0, false)] {
        let (shell, _, window) = try issue281FooterScene(width: width)
        defer { window.close() }
        let hint = try #require(issue281FooterView("grid.keyboard-hint", in: shell))
        #expect(!hint.isHidden == visible, "Space hint at \(width)")
    }
}

@Test @MainActor func issue281SearchEditorDoesNotOverlapHintOrStatusInEnglishAndChinese() throws {
    for language in ["en", "zh-Hans"] {
        let (shell, _, window) = try issue281FooterScene(width: 1280)
        defer { window.close() }
        let longName = language == "en" ? String(repeating: "LongEnglishFileName", count: 20) + ".jpg"
            : String(repeating: "旅行照片文件名", count: 20) + ".jpg"
        shell.setCurrentFile(longName)
        shell.setSearchStatus(resultCount: 12, term: "")
        let hint = try #require(issue281FooterView("grid.keyboard-hint", in: shell))
        let file = try #require(issue281FooterView("grid.current-file-status", in: shell))
        let count = try #require(issue281FooterView("grid.folder-count", in: shell))
        shell.focusSearch()
        shell.layoutSubtreeIfNeeded()
        // grid-light.html: editing uses searchField's frame, not the hidden searchButton or the Space hint.
        #expect(!shell.searchField.isHidden)
        #expect(hint.isHidden, "\(language) Space hint overlaps the editor")
        for status in [file, count] {
            #expect(!status.isHidden, "\(language) status should remain visible")
            #expect(!NSIntersectsRect(status.frame, shell.searchField.frame),
                    "\(language) status overlaps the editor")
        }
        shell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
            object: shell.searchField))
        #expect(!hint.isHidden, "Space hint returns after editing ends")
    }
}

@Test @MainActor func issue281FooterStatusUsesPinnedResponsiveWidths() throws {
    let cases: [(width: CGFloat, fileWidth: CGFloat, countGap: CGFloat, countHidden: Bool)] = [
        (1280, 240, 12, false), (801, 240, 12, false), (800, 180, 7, false),
        (721, 180, 7, false), (720, 140, 7, false), (481, 140, 7, false), (480, 90, 7, true),
    ]
    for item in cases {
        let (shell, _, window) = try issue281FooterScene(width: item.width)
        defer { window.close() }
        let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
        let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
        // grid-light.html: .grid-file-status>span:first-child max-width is 240/180/140/90px; .grid-file-status gap becomes 7px at 800px.
        #expect(abs(file.frame.width - 4 - item.fileWidth) <= 1, "filename text width at \(item.width)")
        #expect(count.isHidden == item.countHidden, "count visibility at \(item.width)")
        #expect(abs(count.frame.minX - file.frame.maxX + 4 - item.countGap) <= 1, "count text gap at \(item.width)")
    }
}

@Test @MainActor func issue281FooterCountFollowsShortNameWithoutTruncation() throws {
    let (shell, grid, window) = try issue281FooterScene(width: 1280)
    defer { window.close() }
    let other = try #require(grid.displayedItemIDs.first)
    grid.activate(currentItemID: other)
    shell.layoutSubtreeIfNeeded()
    let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
    let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
    // grid-light.html: span:first-child hugs `DSC_0342.jpg` (x 63–143) and the count follows 12px later (x 155).
    #expect(file.stringValue == "DSC_0340.jpg")
    #expect(file.frame.width == ceil(file.cell?.cellSize.width ?? 0))
    #expect(count.frame.minX - file.frame.maxX == 8, "12pt between the text boxes")
    #expect(count.frame.minX < 180, "count sits after the name, not in a 240pt column")
    #expect(count.frame.width >= ceil(count.cell?.cellSize.width ?? .infinity), "\(count.stringValue) is truncated")

    // A larger count after the last layout must still fit in full (device: `20000 张…`).
    shell.setSearchStatus(resultCount: 20000, term: "")
    shell.layoutSubtreeIfNeeded()
    #expect(count.stringValue == "20000 images")
    #expect(count.frame.width >= ceil(count.cell?.cellSize.width ?? .infinity), "\(count.stringValue) is truncated")
    #expect(count.frame.minX - file.frame.maxX == 8)
}

/// Device parity-281-282-10301650 FAIL-1/FAIL-5: `DSC_0341.j…`, `12 张…`, `正在读…`. An NSTextField draws its text 2pt
/// inside its frame, so a frame only as wide as the intrinsic text truncates it. The CSS boxes are the text boxes.
@Test @MainActor func issue281FooterLabelsFitTheirCellsAfterControllerUpdates() throws {
    let (shell, grid, window) = try issue281FooterScene(width: 1280)
    defer { window.close() }
    let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
    let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
    func textBox(_ field: NSTextField) -> NSRect { field.frame.insetBy(dx: 2, dy: 0) }
    func expectFits(_ field: NSTextField, _ step: String) {
        let needed = ceil(field.cell?.cellSize.width ?? .infinity)
        #expect(field.frame.width >= needed, "\(step): `\(field.stringValue)` truncated (\(field.frame.width) < \(needed))")
    }
    // The scene is laid out once; from here only the controller calls change the strings.
    let first = try #require(grid.displayedItemIDs.first)
    grid.activate(currentItemID: first)
    shell.layoutSubtreeIfNeeded()
    expectFits(file, "activate")
    expectFits(count, "activate")
    for name in ["DSC_0341.jpg", "山海之间 0341.jpg"] {
        for total in [12, 20000] {
            shell.setCurrentFile(name)
            shell.setSearchStatus(resultCount: total, term: "")
            shell.layoutSubtreeIfNeeded()
            expectFits(file, "\(name) \(total)")
            expectFits(count, "\(name) \(total)")
            // grid-light.html: name text at x 63, count text 12px after it (x 155 after `DSC_0342.jpg`).
            #expect(textBox(file).minX == 63)
            #expect(textBox(count).minX - textBox(file).maxX == 12)
        }
    }

    // folder-loading.html uses U+2014 and a 12px text gap. Preserve the gap after the native font’s actual glyph width.
    shell.setReadingStatus(true)
    shell.layoutSubtreeIfNeeded()
    #expect(file.stringValue == "—")
    expectFits(file, "reading")
    expectFits(count, "reading")
    #expect(textBox(file).minX == 63)
    #expect(textBox(count).minX - textBox(file).maxX == 12)
    shell.setReadingStatus(false)
    shell.layoutSubtreeIfNeeded()
    expectFits(file, "after reading")
    expectFits(count, "after reading")
}

/// Audit F1: a long search summary must not take the filename's slot, hidden (480pt) or beside the editor (800pt).
@Test @MainActor func issue281LongSearchSummaryLeavesTheFilenameSlot() throws {
    let term = String(repeating: "DSC_034", count: 12)
    do {
        let (shell, _, window) = try issue281FooterScene(width: 480)
        defer { window.close() }
        let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
        let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
        shell.setCurrentFile("DSC_0341.jpg")
        shell.setSearchStatus(resultCount: 1, term: term)
        shell.layoutSubtreeIfNeeded()
        #expect(count.isHidden)
        #expect(count.frame.width == 0, "a hidden status reserves no width")
        #expect(file.frame.width >= ceil(file.cell?.cellSize.width ?? .infinity), "480: filename lost its slot")
    }
    do {
        let (shell, _, window) = try issue281FooterScene(width: 800)
        defer { window.close() }
        let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
        let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
        shell.setCurrentFile("DSC_0341.jpg")
        shell.setSearchStatus(resultCount: 1, term: term)
        shell.focusSearch()
        shell.layoutSubtreeIfNeeded()
        #expect(!count.isHidden)
        #expect(file.frame.width >= ceil(file.cell?.cellSize.width ?? .infinity), "800: filename lost its slot")
        // grid-light.html at 800px: 7px between the text boxes; the summary ends 16pt before the editor.
        #expect(count.frame.minX - file.frame.maxX == 3)
        #expect(count.frame.maxX <= shell.searchField.frame.minX - 16)
        #expect(count.frame.width > 0)
        #expect(count.frame.width < ceil(count.cell?.cellSize.width ?? 0), "the long summary is truncated")
        #expect(count.lineBreakMode == .byTruncatingTail)
    }
}

@Test @MainActor func issue281FooterTextIsCentredInFortyPointFooter() throws {
    let (shell, _, window) = try issue281FooterScene(width: 1280)
    defer { window.close() }
    let file = try #require(issue281FooterView("grid.current-file-status", in: shell) as? NSTextField)
    let count = try #require(issue281FooterView("grid.folder-count", in: shell) as? NSTextField)
    // grid-light.html: .grid-bottom-bar align-items:center; text box y 772–789 in the 760–800 footer (device 768–778).
    for field in [file, count] {
        let frame = shell.footer.convert(field.bounds, from: field)
        #expect(abs(frame.height - ceil(field.intrinsicContentSize.height)) <= 1, "\(field.stringValue) one line high")
        #expect(abs(frame.midY - shell.footer.bounds.midY) <= 1, "\(field.stringValue) centred")
    }
}
