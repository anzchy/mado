import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@MainActor private final class MultiPreviewPresentationHost: ViewerSessionHost {
    let presentation: GridViewerPresentation
    let grid: GridBrowserView
    let snapshot: () -> FolderSnapshot
    let offset: NSPoint
    var hasImage = true
    init(presentation: GridViewerPresentation, grid: GridBrowserView,
         snapshot: @escaping () -> FolderSnapshot, offset: NSPoint) {
        self.presentation = presentation; self.grid = grid; self.snapshot = snapshot; self.offset = offset
    }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { presentation.showViewer() }
    func returnToGrid() {
        presentation.restoreGrid(snapshot(), selection: session!.selection, offset: offset)
    }
    weak var session: ViewerSession?
}

@Test @MainActor func gridPresentationRestoresReconciledMultiSelectionAndOffsetAfterSpaceEscape() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-preview-presentation")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<30).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let ids = entries.map(\.itemID)
    func snapshot(_ entries: [FolderEntry], _ generation: UInt64) -> FolderSnapshot {
        FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: generation),
            entries: entries, isComplete: true)
    }
    var shown = snapshot(entries, 1)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    let canvas = NSView(), chrome = NSView(), state = NSView(), inspector = NSView()
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state,
        grid: grid, inspector: inspector)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    session.select(ids[2]); session.select(ids[5], modifier: .command); session.select(ids[8], modifier: .command)
    grid.display(shown, selection: session.selection)
    grid.layoutSubtreeIfNeeded(); grid.collectionView.layoutSubtreeIfNeeded()
    grid.restoreContentOffset(NSPoint(x: 0, y: 75))
    let offset = grid.contentOffset
    let host = MultiPreviewPresentationHost(presentation: presentation, grid: grid,
        snapshot: { shown }, offset: offset)
    host.session = session
    session.host = host
    #expect(CommandRouter().route(.preview, from: .key, to: session))
    #expect(session.previewSet?.itemIDs == [ids[2], ids[5], ids[8]])
    #expect(!presentation.isGridVisible)
    shown = snapshot(entries.filter { $0.itemID != ids[5] }, 2)
    session.updateItems(shown.navigationEntries.map(\.itemID), sourceVersion: .init(2))
    #expect(CommandRouter().route(.escape, from: .key, to: session))
    #expect(presentation.isGridVisible)
    #expect(grid.selection.selectedItemIDs == [ids[2], ids[8]])
    #expect(Set(grid.collectionView.selectionIndexPaths.compactMap { grid.itemID(at: $0.item) }) ==
        session.selection.selectedItemIDs)
    #expect(grid.currentItemID == session.selection.currentItemID)
    #expect(grid.contentOffset == offset)
}

@Test @MainActor func gridSpaceEntryKeepsMultiSelectionAndUsesVisibleGridOrder() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-space-entry")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<7).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let ids = entries.map(\.itemID)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    session.select(ids[1]); session.select(ids[3], modifier: .command); session.select(ids[5], modifier: .command)
    let selected = session.selection
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView())
    let remaining = entries.filter { $0.itemID != ids[3] }
    let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 2),
        entries: remaining, isComplete: true)
    grid.display(snapshot, selection: selected)
    presentation.beginPreview(session, snapshot: snapshot, scrollAnchor: ids[5])
    #expect(session.selection.selectedItemIDs == [ids[1], ids[5]])
    #expect(CommandRouter().route(.preview, from: .key, to: session))
    #expect(session.previewSet?.itemIDs == [ids[1], ids[5]])
}

@Test @MainActor func gridSpaceEntryWithoutSnapshotDropsStaleSelection() {
    _ = NSApplication.shared
    let session = ViewerSession()
    let id = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [id], sourceVersion: .init(1), scrollAnchor: id)
    session.select(id)
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)), inspector: NSView())
    presentation.beginPreview(session, snapshot: nil, scrollAnchor: nil)
    #expect(session.selection.selectedItemIDs.isEmpty)
    #expect(session.selection.currentItemID == nil)
    #expect(session.scrollAnchor == nil)
}

/// Fix round 6: Retry on the failed-read page starts a read on the shell's reading surface. `resumeReadingFooter`
/// shows the reading footer only there: a read is starting, the shell is shown and the grid is hidden.
@MainActor private func resumeReadingLabel(_ id: String, in view: NSView) -> NSTextField? {
    if view.accessibilityIdentifier() == id { return view as? NSTextField }
    return view.subviews.lazy.compactMap { resumeReadingLabel(id, in: $0) }.first
}
@MainActor private struct ResumeReadingFixture {
    let shell: GridShellView, grid: GridBrowserView, presentation: GridViewerPresentation, window: NSWindow
    init() {
        _ = NSApplication.shared
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
            preferencesStore: InMemoryDisplayPreferencesStore())
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        let folder = URL(fileURLWithPath: "/tmp/picsee-resume-reading")
        shell.showFolderTree(current: GridSidebarFolder(url: folder, count: nil), parent: nil, children: [])
        presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
            grid: grid, inspector: NSView(), shell: shell)
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
        let entries = (0..<3).map { FolderEntry(url: folder.appendingPathComponent("DSC_000\($0).jpg"), root: root) }
        presentation.showCompletedGrid(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
            entries: entries, isComplete: true), selection: BrowserSelection(), currentItemID: entries[0].itemID, offset: nil)
    }
    /// The failed-read surface: the reading surface after the failure cleared the footer's reading status.
    func showFailedSurface() {
        presentation.showGrid(reading: true)
        shell.setReadingStatus(false)
    }
    var footer: (name: String, count: String, sidebarZero: String?) {
        shell.layoutSubtreeIfNeeded()
        let row = shell.folderTree.rows.first { $0.current }
        let name = resumeReadingLabel("grid.current-file-status", in: shell)
        return (name.map { $0.isHidden ? "" : $0.stringValue } ?? "<missing>", shell.searchStatus.stringValue,
                row.map { $0.countLabel.isHidden ? "" : $0.countLabel.stringValue })
    }
}

@Test @MainActor func resumeReadingFooterShowsReadingOnTheFailedSurface() throws {
    let f = ResumeReadingFixture(); defer { f.window.close() }
    f.showFailedSurface()
    let before = f.footer
    #expect(before.name == "DSC_0000.jpg" && before.count == "3 images")
    #expect(!f.shell.isHidden && !f.presentation.isGridVisible)
    f.presentation.resumeReadingFooter(true)
    #expect(f.footer.name == "–")
    #expect(f.footer.count == "Reading…")
    let row = try #require(f.shell.folderTree.rows.first { $0.current })
    #expect(row.countLabel.stringValue.isEmpty && row.countLabel.isHidden)
    #expect(row.accessibilityLabel() == "picsee-resume-reading")
    #expect(!f.shell.isHidden && !f.presentation.isGridVisible)
}

@Test @MainActor func resumeReadingFooterLeavesTheFooterWhenNoReadStarts() {
    let f = ResumeReadingFixture(); defer { f.window.close() }
    f.showFailedSurface()
    let before = f.footer
    f.presentation.resumeReadingFooter(false)
    #expect(f.footer == before)
    #expect(f.footer.count == "3 images" && !f.shell.folderTree.showsZeroForUnknownCurrent)
}

@Test @MainActor func resumeReadingFooterLeavesAHiddenShellHidden() {
    let f = ResumeReadingFixture(); defer { f.window.close() }
    f.presentation.showViewer()
    let before = f.footer
    f.presentation.resumeReadingFooter(true)
    #expect(f.shell.isHidden)
    #expect(f.footer == before)
    #expect(f.footer.count == "3 images" && !f.shell.folderTree.showsZeroForUnknownCurrent)
}

@Test @MainActor func resumeReadingFooterLeavesTheVisibleGridFooter() {
    let f = ResumeReadingFixture(); defer { f.window.close() }
    #expect(f.presentation.isGridVisible)
    let before = f.footer
    #expect(before.name == "DSC_0000.jpg" && before.count == "3 images")
    f.presentation.resumeReadingFooter(true)
    #expect(f.footer == before)
    #expect(f.presentation.isGridVisible && !f.shell.folderTree.showsZeroForUnknownCurrent)
}

/// Page 24F-A → page 24: Retry removes both the failure dash and its AX status.
@Test @MainActor func i142WI1RetryClearsFailedSidebarCountAndAccessibility() async throws {
    let f = ResumeReadingFixture(); defer { f.window.close() }
    f.showFailedSurface()
    for _ in 0..<2 {
        f.shell.setReadFailedStatus(true)
        let failed = try #require(f.shell.folderTree.rows.first { $0.current })
        #expect(failed.countLabel.stringValue == "—" && !failed.countLabel.isHidden)
        #expect(failed.accessibilityLabel() == "picsee-resume-reading, Read incomplete")
        f.presentation.resumeReadingFooter(true)
        let reading = try #require(f.shell.folderTree.rows.first { $0.current })
        #expect(reading.countLabel.stringValue.isEmpty && reading.countLabel.isHidden)
        #expect(reading.accessibilityLabel() == "picsee-resume-reading")
        #expect(f.footer.name == "–" && f.footer.count == "Reading…")
        #expect(!f.shell.isHidden && !f.presentation.isGridVisible)
        await Task.yield()
    }
}
