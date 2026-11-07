import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

/// A native-effect adapter only: Session chooses the requested image identity and return selection.
@MainActor private final class Issue492ReturnHost: ViewerSessionHost {
    let presentation: GridViewerPresentation
    let snapshot: FolderSnapshot
    weak var session: ViewerSession?
    var hasImage = true
    var presented: [ItemID] = []
    init(presentation: GridViewerPresentation, snapshot: FolderSnapshot) {
        self.presentation = presentation; self.snapshot = snapshot
    }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {
        presented.append(id)
        presentation.showViewer()
    }
    func returnToGrid() {
        guard let session else { return }
        presentation.restoreGrid(snapshot, selection: session.selection, offset: nil)
    }
}

/// GRID-02; owner confirmation in #345 (2026-11-02): last viewed Current Item on return,
/// "same as without a wrap". This test deliberately never crosses a sequence boundary.
@Test(arguments: [1, 3], [false, true]) @MainActor
func issue492ReturningFromViewerFollowsLastViewedImage(arrowCount: Int, returnViaButton: Bool) throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/issue492")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let entries = ["DSC_0341.jpg", "DSC_0342.jpg", "DSC_0343.jpg"].map {
        FolderEntry(url: folder.appendingPathComponent($0), root: root)
    }
    let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    let ids = snapshot.navigationEntries.map(\.itemID)
    let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let content = NSView(frame: frame)
    let shell = GridShellView(frame: frame, preferencesStore: InMemoryDisplayPreferencesStore())
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    let canvas = NSView(frame: frame), chrome = NSView(frame: frame), state = NSView(frame: frame)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    for view in [shell, canvas, chrome, state] { content.addSubview(view) }
    shell.mainContent.addSubview(grid)
    defer { grid.stopThumbnails(); window.close() }
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state,
        grid: grid, inspector: NSView(), shell: shell)
    let session = ViewerSession()
    shell.session = session
    let host = Issue492ReturnHost(presentation: presentation, snapshot: snapshot)
    host.session = session; session.host = host
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[0])
    session.select(ids[0])
    presentation.showCompletedGrid(snapshot, selection: session.selection, currentItemID: ids[0], offset: nil)
    func status(in view: NSView) -> NSTextField? {
        if view.accessibilityIdentifier() == "grid.current-file-status" { return view as? NSTextField }
        return view.subviews.lazy.compactMap { status(in: $0) }.first
    }
    let label = try #require(status(in: shell))
    try #require(grid.currentItemID == ids[0] && label.stringValue == "DSC_0341.jpg")
    let router = CommandRouter()
    try #require(router.route(.enter, from: .key, to: session))
    try #require(host.presented.last == ids[0] && !presentation.isGridVisible)
    try #require(!session.folderLoopEnabled)
    let steps: [CommandID] = arrowCount == 1 ? [.next] : [.next, .next, .previous]
    for command in steps { try #require(router.route(command, from: .key, to: session)) }
    let expected = snapshot.navigationEntries[1]
    // Positive control: the viewer really reached 0342 before returning, for both navigation traces.
    try #require(session.previewSet?.currentItemID == expected.itemID && host.presented.last == expected.itemID)
    if returnViaButton { session.perform(intent: .returnToGrid) }
    else { try #require(router.route(.escape, from: .key, to: session)) }
    try #require(presentation.isGridVisible && session.mode == .browsing)
    #expect(session.selection.selectedItemIDs == [expected.itemID])
    #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    let returnedName = grid.currentItemID.flatMap { grid.entry(for: $0) }?.url.lastPathComponent
    let returnedStatus = label.stringValue
    #expect(session.currentItemID == expected.itemID)
    #expect(grid.currentItemID == expected.itemID)
    #expect(returnedStatus == "DSC_0342.jpg")
    // The same Enter command as Return on the grid must reopen the restored Current Item.
    try #require(router.route(.enter, from: .key, to: session))
    let reopenedName = host.presented.last.flatMap { id in
        snapshot.navigationEntries.first(where: { $0.itemID == id })?.url.lastPathComponent
    }
    #expect(host.presented.last == expected.itemID)
    #expect(reopenedName == "DSC_0342.jpg")
    print("i492 arrows=\(arrowCount) button=\(returnViaButton) viewed=DSC_0342.jpg returned=\(returnedName ?? "nil") status=\(returnedStatus) reopened=\(reopenedName ?? "nil")")
}
