import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

private final class Issue350AppMagnifyEvent: NSEvent {
    var delta: CGFloat = 0
    var gesturePhase: NSEvent.Phase = []
    var point: NSPoint = .zero
    override var type: NSEvent.EventType { .magnify }
    override var magnification: CGFloat { delta }
    override var phase: NSEvent.Phase { gesturePhase }
    override var locationInWindow: NSPoint { point }
}

@MainActor private func issue350AppEvent(_ delta: Double, phase: NSEvent.Phase = .changed, point: NSPoint = .zero) -> NSEvent {
    let event = Issue350AppMagnifyEvent()
    event.delta = CGFloat(delta); event.gesturePhase = phase; event.point = point
    return event
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue350AppPinchSynchronizesRenderedWindowsSettingsAndPersistence() throws {
    let suite = "picsee.app350.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: cacheURL) }
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    var initial = DisplayPreferences(alwaysShowTools: true, appearance: .dark)
    initial.thumbnailSize = 200; initial.thumbnailFit = .fit; initial.loopThroughImages = true
    store.value = initial
    let a = try Issue349AppScene(store: store), b = try Issue349AppScene(store: store)
    let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(directory: cacheURL),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: store), preferencesStore: store,
        defaults: defaults, updates: FakeUpdatePort())
    defer { panel.window.close(); a.close(); b.close() }
    panel.select(.display)
    panel.window.contentView?.layoutSubtreeIfNeeded()
    let slider = try #require(issue349Descendants(panel.window.contentView)
        .first { $0.accessibilityIdentifier() == "settings.display.size" } as? NSSlider)
    for (scene, index) in [(a, 75), (b, 90)] {
        scene.controller.session.select(scene.entries[2].itemID)
        scene.controller.session.select(scene.entries[index].itemID, modifier: .command)
        scene.grid.synchronizeSelection(scene.controller.session.selection)
    }
    // Reveal both late Current Items via the already-existing preference relayout path.
    store.value.thumbnailSize = 220; a.settle(); b.settle()
    let aSelection = a.controller.session.selection, bSelection = b.controller.session.selection
    let beforeA = try a.tile(75).frame.width, beforeB = try b.tile(90).frame.width
    func expectShared(_ size: Double) throws {
        var expected = initial; expected.thumbnailSize = size
        #expect(store.value == expected)
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == expected)
        #expect(slider.doubleValue == size)
        #expect((slider.accessibilityValue() as? NSNumber)?.doubleValue == size)
        for (scene, selected, index) in [(a, aSelection, 75), (b, bSelection, 90)] {
            scene.settle()
            #expect(scene.controller.session.selection == selected && scene.grid.selection == selected)
            #expect(scene.grid.currentItemID == scene.entries[index].itemID)
            #expect(scene.grid.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0), IndexPath(item: index, section: 0)])
            let attributes = try #require(scene.grid.collectionView.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
            let scroll = try #require(scene.grid.collectionView.enclosingScrollView)
            var visible = scroll.contentView.documentVisibleRect
            visible.size.height -= scroll.contentInsets.bottom
            #expect(visible.insetBy(dx: -0.1, dy: -0.1).contains(attributes.frame))
        }
    }
    a.grid.restoreContentOffset(.zero); b.grid.restoreContentOffset(.zero)
    a.grid.collectionView.magnify(with: issue350AppEvent(0, phase: .began))
    a.grid.collectionView.magnify(with: issue350AppEvent(1))
    try expectShared(280)
    #expect(try a.tile(75).frame.width > beforeA && b.tile(90).frame.width > beforeB)
    a.grid.collectionView.magnify(with: issue350AppEvent(-1))
    try expectShared(140)
    #expect(try a.tile(75).frame.width < beforeA && b.tile(90).frame.width < beforeB)
    a.grid.collectionView.magnify(with: issue350AppEvent(0, phase: .ended))
    b.grid.collectionView.magnify(with: issue350AppEvent(0, phase: .began))
    b.grid.collectionView.magnify(with: issue350AppEvent(1))
    try expectShared(280)
    b.grid.collectionView.magnify(with: issue350AppEvent(0, phase: .ended))
    slider.doubleValue = 170
    #expect(slider.sendAction(slider.action, to: slider.target))
    a.grid.collectionView.magnify(with: issue350AppEvent(0, phase: .began))
    a.grid.collectionView.magnify(with: issue350AppEvent(0.05))
    try expectShared(180)
    a.grid.collectionView.magnify(with: issue350AppEvent(0, phase: .ended))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue350ViewerNativePinchStillZoomsImageAfterGridPinch() throws {
    let store = InMemoryDisplayPreferencesStore()
    let gridScene = try Issue349AppScene(store: store)
    let viewer = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
        accessServices: Task<AccessServices, Error> { throw CancellationError() },
        motionPolicy: MotionPolicy(source: Issue349Motion()))
    let window = try #require(viewer.window)
    defer { gridScene.close(); window.close() }
    gridScene.grid.collectionView.magnify(with: issue350AppEvent(1))
    #expect(store.value.thumbnailSize == 280)
    let before = store.value
    let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    viewer.installImage(DecodedImage(image: try #require(context.makeImage()),
        sourcePixelSize: CGSize(width: 800, height: 400)), fileURL: URL(fileURLWithPath: "/tmp/issue350/viewer.png"))
    let canvas = try #require(issue349Descendants(window.contentView).compactMap { $0 as? CanvasInputBridge }.first)
    let point = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
    canvas.magnify(with: issue350AppEvent(log(1.2), point: point))
    guard case .custom(let enlarged) = viewer.session.zoomMode else { Issue.record("viewer pinch must set custom zoom"); return }
    canvas.magnify(with: issue350AppEvent(-log(1.2), point: point))
    guard case .custom(let reduced) = viewer.session.zoomMode else { Issue.record("viewer reverse pinch must retain custom zoom"); return }
    #expect(enlarged > reduced && reduced > 0)
    #expect(store.value == before)
    let hiddenGrid = try #require(issue349Descendants(window.contentView).compactMap { $0 as? GridBrowserView }.first)
    #expect(hiddenGrid.isHiddenOrHasHiddenAncestor)
    hiddenGrid.collectionView.magnify(with: issue350AppEvent(-1))
    #expect(store.value == before)
}
