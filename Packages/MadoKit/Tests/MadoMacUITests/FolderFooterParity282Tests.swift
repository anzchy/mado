import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private func issue282FooterView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let match = issue282FooterView(id, in: child) { return match }
    }
    return nil
}

@Test @MainActor func issue282ReadingFooterShowsReadingStatusAndPreservesRealSidebarCount() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    grid.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(grid)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = shell
    let folder = URL(fileURLWithPath: "/tmp/mado-reading-282")
    let current = GridSidebarFolder(url: folder, count: 20000)
    shell.showFolderTree(current: current, parent: nil, children: [])
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView(), shell: shell)
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<3).map { FolderEntry(url: folder.appendingPathComponent("DSC_000\($0).jpg"), root: root) }
    let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    presentation.showCompletedGrid(snapshot, selection: BrowserSelection(), currentItemID: entries[0].itemID, offset: nil)
    presentation.showGrid(reading: true)
    shell.layoutSubtreeIfNeeded()

    let status = try #require(issue282FooterView("grid.current-file-status", in: shell) as? NSTextField)
    let count = try #require(issue282FooterView("grid.folder-count", in: shell) as? NSTextField)
    // folder-loading.html: `<span>—</span><span class="grid-folder-count">正在读取…</span>` text at x 63 and 82, gap 12;
    // Keep the pinned U+2014 glyph; frames add 2pt of text inset on each side.
    #expect(status.stringValue == "—")
    #expect(!status.isHidden)
    #expect(status.frame.minX == 61)
    #expect(status.frame.width == ceil(status.cell?.cellSize.width ?? 0))
    #expect(count.stringValue == "Reading…")
    #expect(!count.isHidden)
    #expect(count.font == .monospacedSystemFont(ofSize: 12, weight: .regular))
    #expect(count.frame.minX - status.frame.maxX == 8)
    #expect(count.frame.width >= ceil(count.cell?.cellSize.width ?? .infinity))
    for field in [status, count] {
        #expect(abs(field.frame.midY - shell.footer.bounds.midY) <= 1, "\(field.stringValue) centred")
    }
    let hint = try #require(issue282FooterView("grid.keyboard-hint", in: shell))
    #expect(hint.isHidden)
    let row = try #require(shell.folderTree.rows.first)
    #expect(row.countLabel.stringValue == "20000")

    // Cancel Reading back to the grid restores the current name and the image count.
    presentation.showGrid(reading: false)
    shell.layoutSubtreeIfNeeded()
    #expect(status.stringValue == "DSC_0000.jpg")
    #expect(count.stringValue == "3 images")
    #expect(!count.isHidden)
}

/// #142 owner decision / page 24: an unknown count is absent visually and from the AX label.
@Test @MainActor func issue282SidebarLeavesUnknownCountBlankForTheFolderBeingRead() async throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    shell.mainContent.addSubview(grid)
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView(), shell: shell)
    let folder = URL(fileURLWithPath: "/tmp/mado-reading-282-unknown")
    @MainActor func expectCount(_ count: Int?) throws {
        let row = try #require(shell.folderTree.rows.first(where: { $0.current }))
        #expect(row.countLabel.stringValue == (count.map(String.init) ?? ""))
        #expect(row.countLabel.isHidden == (count == nil))
        let images = count.map { String(format: String(localized: "%lld images"), Int64($0)) }
        #expect(row.accessibilityLabel() == (images.map { "\(folder.lastPathComponent), \($0)" } ?? folder.lastPathComponent))
    }
    shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil,
        children: [GridSidebarFolder(url: folder.appendingPathComponent("child"))])
    presentation.showGrid(reading: true)
    try expectCount(nil)
    let child = try #require(shell.folderTree.rows.first(where: { !$0.current }))
    #expect(child.countLabel.stringValue.isEmpty && child.countLabel.isHidden)
    #expect(child.accessibilityLabel() == "child")
    await Task.yield()

    // Late sidebar arrival and repeated nil updates cannot create a count.
    shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil, children: [])
    try expectCount(nil)
    shell.updateFolderCount(nil, for: folder)
    try expectCount(nil)
    presentation.showGrid(reading: true)
    try expectCount(nil)
    presentation.showGrid(reading: false)
    try expectCount(nil)
    await Task.yield()

    // A real count (including completed zero) survives reading toggles and tree rebuilds.
    for count in [12, 0] {
        shell.updateFolderCount(count, for: folder)
        try expectCount(count)
        presentation.showGrid(reading: true)
        try expectCount(count)
        shell.showFolderTree(current: GridSidebarFolder(url: folder, count: count), parent: nil, children: [])
        try expectCount(count)
        presentation.showGrid(reading: false)
        try expectCount(count)
        await Task.yield()
    }
    shell.updateFolderCount(nil, for: folder)
    presentation.showGrid(reading: true)
    try expectCount(nil)
}
