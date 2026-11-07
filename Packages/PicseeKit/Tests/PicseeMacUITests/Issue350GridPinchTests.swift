import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

/// Only the native event fields are synthetic; responder, layout, store and shell are real.
private final class Issue350MagnifyEvent: NSEvent {
    var delta: CGFloat = 0
    var gesturePhase: NSEvent.Phase = []
    override var type: NSEvent.EventType { .magnify }
    override var magnification: CGFloat { delta }
    override var phase: NSEvent.Phase { gesturePhase }
    override var locationInWindow: NSPoint { .zero }
}

@MainActor private final class Issue350GridScene {
    let store = InMemoryDisplayPreferencesStore(DisplayPreferences(alwaysShowTools: true, appearance: .dark))
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    let shell: GridShellView
    let window: NSWindow
    let snapshot: FolderSnapshot
    let selection: BrowserSelection
    var current: ItemID { snapshot.entries[83].itemID }
    init() throws {
        _ = NSApplication.shared
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), preferencesStore: store)
        grid.frame = shell.mainFrame
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: shell.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/issue350"))
        let entries = (0..<100).map { FolderEntry(url: root.url.appendingPathComponent("IMG_\($0).jpg"), root: root) }
        snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: root.url, generation: 1), entries: entries, isComplete: true)
        var selected = BrowserSelection()
        selected.click(entries[2].itemID, in: entries.map(\.itemID))
        selected.click(entries[83].itemID, modifier: .command, in: entries.map(\.itemID))
        selection = selected
        grid.display(snapshot, selection: selection)
        grid.activate()
        settle()
    }
    func settle() {
        shell.layoutSubtreeIfNeeded(); grid.layoutSubtreeIfNeeded(); grid.collectionView.layoutSubtreeIfNeeded()
        for item in grid.collectionView.visibleItems() { item.view.layoutSubtreeIfNeeded() }
    }
    func event(_ delta: Double, _ phase: NSEvent.Phase = .changed, onGrid: Bool = false) {
        let event = Issue350MagnifyEvent()
        event.delta = CGFloat(delta); event.gesturePhase = phase
        if onGrid { grid.magnify(with: event) } else { grid.collectionView.magnify(with: event) }
        settle()
    }
    func tileWidth() throws -> CGFloat {
        let cell = try #require(grid.collectionView.item(at: IndexPath(item: 83, section: 0)) as? GridPhotoItem)
        return try #require(cell.tileLayer).frame.width
    }
    func expectConserved() throws {
        #expect(grid.selection == selection && grid.currentItemID == current)
        #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0), IndexPath(item: 83, section: 0)])
        let attributes = try #require(grid.collectionView.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 83, section: 0)))
        let scroll = try #require(grid.collectionView.enclosingScrollView)
        var visible = scroll.contentView.documentVisibleRect
        visible.size.height -= scroll.contentInsets.bottom
        #expect(visible.insetBy(dx: -0.1, dy: -0.1).contains(attributes.frame))
    }
    func close() { grid.stopThumbnails(); window.contentView = nil; window.close() }
}

@Suite(.serialized) struct Issue350GridPinchTests {
    @Test @MainActor func issue350NativeGridPinchRendersAndConservesState() throws {
        let scene = try Issue350GridScene()
        defer { scene.close() }
        // Establish the current item's rendered frame, then deliberately move it out of view.
        scene.store.value.thumbnailSize = 200; scene.settle()
        let before = try scene.tileWidth()
        scene.grid.restoreContentOffset(.zero)
        scene.event(0, .began)
        scene.event(1)
        #expect(scene.store.value.thumbnailSize == 280)
        try scene.expectConserved()
        #expect(try scene.tileWidth() > before)
        scene.event(-0.05)
        #expect(scene.store.value.thumbnailSize == 270)
        try scene.expectConserved()
        scene.event(-1, onGrid: true)
        #expect(scene.store.value.thumbnailSize == 140)
        try scene.expectConserved()
        #expect(try scene.tileWidth() < before)
        scene.event(0.05)
        #expect(scene.store.value.thumbnailSize == 150)
        try scene.expectConserved()
        scene.event(0, .ended)
        var expected = DisplayPreferences(alwaysShowTools: true, appearance: .dark)
        expected.thumbnailSize = 150
        #expect(scene.store.value == expected)
    }

    @Test @MainActor func issue350FractionalEventsResetAndFollowExternalPreferences() throws {
        let scene = try Issue350GridScene()
        defer { scene.close() }
        scene.event(0, .began)
        for _ in 0..<20 { scene.event(0.005) }
        #expect(scene.store.value.thumbnailSize == 240, "sub-step events accumulate while still in progress")
        scene.event(0, .ended)
        scene.event(0, .began)
        for _ in 0..<20 { scene.event(-0.005) }
        #expect(scene.store.value.thumbnailSize == 220)
        scene.event(0, .ended)
        for terminal: NSEvent.Phase in [.ended, .cancelled] {
            scene.store.value.thumbnailSize = 220
            scene.event(0, .began); scene.event(0.02); scene.event(0, terminal)
            scene.event(0.02)
            #expect(scene.store.value.thumbnailSize == 220, "\(terminal) discards fractional residue")
            scene.event(0, .ended)
        }
        scene.event(0, .began); scene.event(0.02)
        scene.event(0.02, .began)
        #expect(scene.store.value.thumbnailSize == 220, "new began resets previous fractional residue")
        scene.store.value.thumbnailSize = 170
        scene.event(0.05)
        #expect(scene.store.value.thumbnailSize == 180, "external change during an active gesture replaces its base")
        scene.event(0, .ended)
        scene.store.value.thumbnailSize = 170
        scene.event(0, .began); scene.event(0.05)
        #expect(scene.store.value.thumbnailSize == 180)
        scene.event(0, .ended)
        scene.event(0, .began); scene.event(0.05, .ended)
        #expect(scene.store.value.thumbnailSize == 190, "final event delta is applied once")
        scene.event(0, .began); scene.event(0, .ended)
        #expect(scene.store.value.thumbnailSize == 190)
        for delta in [Double.nan, .infinity, -.infinity] { scene.event(delta) }
        #expect(scene.store.value.thumbnailSize == 190)
        scene.grid.isHidden = true
        scene.event(1)
        #expect(scene.store.value.thumbnailSize == 190)
        scene.grid.isHidden = false
        scene.event(0, .ended)
        try scene.expectConserved()
    }
}
