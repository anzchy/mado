import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

private func thumbnailPixel(_ value: UInt8) -> CGImage {
    let data = Data([value, 0, 0, 255])
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func thumbnailFixture(_ name: String) -> FolderEntry {
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000118")!),
        url: URL(fileURLWithPath: "/tmp/mado-grid-thumbnails"))
    return FolderEntry(url: root.url.appendingPathComponent(name), root: root)
}

private func thumbnailRequest(_ entry: FolderEntry, edge: Int, revision: Int) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID,
        revision: FileRevision(byteCount: revision, modificationDate: nil), maximumPixelSize: edge)
    let request = ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key)
    let image = DecodedImage(image: thumbnailPixel(UInt8(revision)), sourcePixelSize: CGSize(width: 1, height: 1),
        revision: key.revision, itemID: entry.itemID)
    return (request, image)
}

private func thumbnailRequest(_ entry: FolderEntry, edge coverage: ThumbnailCoverage, revision: Int) -> (ImageDecodeRequest, DecodedImage) {
    thumbnailRequest(entry, edge: coverage.fallbackEdge, revision: revision)
}

private actor GridThumbnailRequestLog {
    private var requested: Set<ItemID> = []
    private var waiters: [ItemID: [CheckedContinuation<Void, Never>]] = [:]
    func add(_ id: ItemID) {
        requested.insert(id)
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    func contains(_ id: ItemID) -> Bool { requested.contains(id) }
    func waitFor(_ id: ItemID) async {
        if requested.contains(id) { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
}

private actor GridThumbnailEdgeLog {
    private var edges: [Int] = []
    func add(_ edge: Int) { edges.append(edge) }
    func add(_ coverage: ThumbnailCoverage) { edges.append(coverage.fallbackEdge) }
    func contains(_ edge: Int) -> Bool { edges.contains(edge) }
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridThumbnailRequestsFollowSidebarMainColumnSize() async throws {
    _ = NSApplication.shared
    let store = InMemoryDisplayPreferencesStore()
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772), preferencesStore: store)
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    grid.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(grid)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [], backing: .buffered, defer: false)
    window.contentView!.addSubview(shell)
    let entry = thumbnailFixture("Resize.jpg")
    let rootID = AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000118")!)
    let snapshot = FolderSnapshot(version: .init(rootID: rootID,
        folder: entry.url.deletingLastPathComponent(), generation: 1), entries: [entry], isComplete: true)
    let log = GridThumbnailEdgeLog()
    grid.thumbnailLoader = { entry, _, edge, _ in
        await log.add(edge)
        return thumbnailRequest(entry, edge: edge, revision: 1)
    }
    shell.layoutSubtreeIfNeeded()
    grid.display(snapshot, selectedItemID: nil)
    grid.setThumbnailsActive(true)
    let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
    func expectedEdge() -> Int {
        GridThumbnailPixelSizing.edge(tile: NSSize(width: layout.itemSize.width - 8,
            height: layout.itemSize.height - 36), backingScale: window.backingScaleFactor)
    }
    func awaitRequest(_ edge: Int) async throws {
        try await waitUntil { await log.contains(edge) }
        #expect(await log.contains(edge))
    }
    let initial = expectedEdge()
    try await awaitRequest(initial)
    shell.resizeSidebar(to: 320)
    shell.layoutSubtreeIfNeeded()
    grid.layoutSubtreeIfNeeded()
    let resized = expectedEdge()
    #expect(resized != initial)
    try await awaitRequest(resized)
    shell.toggleSidebar()
    shell.layoutSubtreeIfNeeded()
    grid.layoutSubtreeIfNeeded()
    let expanded = expectedEdge()
    #expect(expanded != resized && expanded != initial)
    try await awaitRequest(expanded)
    grid.stopThumbnails()
}

private actor HeldGridImagePort {
    private var waiting: [ItemID: CheckedContinuation<(ImageDecodeRequest, DecodedImage), Never>] = [:]
    private var values: [ItemID: (ImageDecodeRequest, DecodedImage)] = [:]
    private var waiters: [ItemID: [CheckedContinuation<Void, Never>]] = [:]
    func load(_ entry: FolderEntry, edge coverage: ThumbnailCoverage, revision: Int) async -> (ImageDecodeRequest, DecodedImage) {
        let edge = coverage.fallbackEdge
        let value = thumbnailRequest(entry, edge: edge, revision: revision)
        return await withCheckedContinuation { continuation in
            values[entry.itemID] = value
            waiting[entry.itemID] = continuation
            for waiter in waiters.removeValue(forKey: entry.itemID) ?? [] { waiter.resume() }
        }
    }
    func has(_ id: ItemID) -> Bool { waiting[id] != nil }
    func waitFor(_ id: ItemID) async {
        if waiting[id] != nil { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    func release(_ id: ItemID) { if let value = values.removeValue(forKey: id) { waiting.removeValue(forKey: id)?.resume(returning: value) } }
}

@Test @MainActor func gridMultiSelectionKeepsThumbnailAcrossRedrawAndCellReuse() async throws {
    _ = NSApplication.shared
    let a = thumbnailFixture("Selected-A.jpg"), b = thumbnailFixture("Selected-B.jpg")
    let snapshot = FolderSnapshot(version: .init(rootID: AccessRootID(rawValue:
        UUID(uuidString: "00000000-0000-0000-0000-000000000118")!),
        folder: a.url.deletingLastPathComponent(), generation: 1), entries: [a, b], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.thumbnailLoader = { entry, _, edge, _ in thumbnailRequest(entry, edge: edge, revision: 7) }
    var selection = BrowserSelection()
    selection.click(a.itemID, in: [a.itemID, b.itemID])
    selection.click(b.itemID, modifier: .command, in: [a.itemID, b.itemID])
    grid.display(snapshot, selection: selection)
    grid.setThumbnailsActive(true)
    grid.layoutSubtreeIfNeeded()
    for index in 0..<2 { await grid.waitForThumbnail(at: index) }

    func assertCell(_ index: Int, selected: Bool, phase: String) throws {
        let cell = try #require(grid.collectionView.item(at: IndexPath(item: index, section: 0)) as? GridPhotoItem)
        #expect(cell.representedItemID == [a, b][index].itemID)
        #expect(cell.tileLayer?.contents != nil)
        #expect(cell.isSelected == selected, "\(phase) cell \(index)")
        // Owner decision 2026-11-03 (#405): no ✓ badge at any selection count.
        #expect(gridCheckGlyphs(in: cell.view).isEmpty, "\(phase) cell \(index)")
    }
    try assertCell(0, selected: true, phase: "loaded")
    try assertCell(1, selected: true, phase: "loaded")
    selection.click(a.itemID, modifier: .command, in: [a.itemID, b.itemID])
    grid.synchronizeSelection(selection)
    try assertCell(0, selected: false, phase: "redrawn")
    try assertCell(1, selected: true, phase: "redrawn")
    grid.collectionView.reloadItems(at: [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)])
    grid.layoutSubtreeIfNeeded()
    try assertCell(0, selected: false, phase: "reloaded")
    try assertCell(1, selected: true, phase: "reloaded")
    grid.stopThumbnails()
}

@Test @MainActor func gridThumbnailBindingRejectsReuseRevisionAndScale() {
    _ = NSApplication.shared
    let a = thumbnailFixture("A.jpg"), b = thumbnailFixture("B.jpg")
    let cell = GridPhotoItem()
    cell.configure(a)
    cell.beginThumbnail(generation: 1, pixelEdge: 212)
    let oldToken = cell.thumbnailToken
    let (oldRequest, oldImage) = thumbnailRequest(a, edge: 212, revision: 1)
    cell.configure(b)
    cell.beginThumbnail(generation: 2, pixelEdge: 424)
    let currentToken = cell.thumbnailToken
    #expect(!cell.installThumbnail(oldRequest, image: oldImage, token: oldToken, generation: 1, pixelEdge: 212))
    #expect(cell.tileLayer?.contents == nil)
    let (wrongSizeRequest, wrongSizeImage) = thumbnailRequest(b, edge: 212, revision: 2)
    #expect(!cell.installThumbnail(wrongSizeRequest, image: wrongSizeImage, token: currentToken, generation: 2, pixelEdge: 212))
    let (request, image) = thumbnailRequest(b, edge: 424, revision: 2)
    #expect(cell.installThumbnail(request, image: image, token: currentToken, generation: 2, pixelEdge: 424))
    #expect(cell.tileLayer?.contents != nil)
    #expect(cell.view.accessibilityLabel() == "B.jpg")
    #expect(!cell.installThumbnail(oldRequest, image: oldImage, token: oldToken, generation: 1, pixelEdge: 212))
    #expect(cell.filename == "B.jpg")
}

@Test @MainActor func gridThumbnailFailureIsTruthfulAndRecoverable() {
    _ = NSApplication.shared
    let a = thumbnailFixture("Broken.jpg")
    let cell = GridPhotoItem()
    cell.configure(a)
    cell.beginThumbnail(generation: 1, pixelEdge: 212)
    let token = cell.thumbnailToken
    cell.thumbnailUnavailable(token: token)
    #expect(cell.tileLayer?.contents == nil)
    #expect(cell.view.accessibilityLabel()?.contains("unavailable") == true)
    cell.beginThumbnail(generation: 2, pixelEdge: 212)
    let (request, image) = thumbnailRequest(a, edge: 212, revision: 3)
    #expect(cell.installThumbnail(request, image: image, token: cell.thumbnailToken, generation: 2, pixelEdge: 212))
    #expect(cell.tileLayer?.contents != nil)
    #expect(cell.view.accessibilityLabel() == "Broken.jpg")
}

@Test @MainActor func gridVisibleCellLoadsPixelsAndFailureRemainsTruthful() async throws {
    _ = NSApplication.shared
    let a = thumbnailFixture("Visible.jpg"), broken = thumbnailFixture("Broken.png")
    let rootID = AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000118")!)
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: a.url.deletingLastPathComponent(), generation: 1),
        entries: [a, broken], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.thumbnailLoader = { entry, _, edge, _ in
        if entry.itemID == broken.itemID { throw CocoaError(.fileReadCorruptFile) }
        return thumbnailRequest(entry, edge: edge, revision: 5)
    }
    grid.display(snapshot, selectedItemID: nil)
    grid.setThumbnailsActive(true)
    grid.layoutSubtreeIfNeeded()
    let goodIndex = try #require(grid.index(for: a.itemID))
    let badIndex = try #require(grid.index(for: broken.itemID))
    await grid.waitForThumbnail(at: goodIndex)
    await grid.waitForThumbnail(at: badIndex)
    let good = try #require(grid.collectionView.item(at: IndexPath(item: goodIndex, section: 0)) as? GridPhotoItem)
    let bad = try #require(grid.collectionView.item(at: IndexPath(item: badIndex, section: 0)) as? GridPhotoItem)
    #expect(good.tileLayer?.contents != nil)
    #expect(good.view.accessibilityLabel() == "Visible.jpg")
    #expect(good.tileLayer?.masksToBounds == true)
    #expect(good.tileLayer?.contentsGravity == .resizeAspectFill)
    let name = try #require(good.view.subviews.compactMap { $0 as? NSTextField }
        .first { $0.stringValue == "Visible.jpg" })
    let tile = try #require(good.view.subviews.first { $0.layer === good.tileLayer })
    #expect(name.frame.maxY < tile.frame.minY)
    #expect(good.currentRingLayer.superlayer === good.view.layer)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        good.view.appearance = NSAppearance(named: appearance)
        #expect(good.tileLayer?.contents != nil)
        #expect(name.frame.maxY < tile.frame.minY)
    }
    #expect(bad.tileLayer?.contents == nil)
    #expect(bad.view.accessibilityLabel()?.contains("unavailable") == true)
    good.configure(a) // A reused visible cell catches up from the completed scheduler record.
    bad.configure(broken) // A reused failed cell catches up from the retained failure.
    grid.setThumbnailsActive(true)
    #expect(good.tileLayer?.contents != nil)
    #expect(bad.view.accessibilityLabel()?.contains("unavailable") == true)
    let installsBeforeScrollTick = good.thumbnailInstallCount
    grid.setThumbnailsActive(true) // Reconcile a completed nearby result into an already visible cell.
    grid.setThumbnailsActive(true)
    #expect(good.thumbnailInstallCount == installsBeforeScrollTick)
    grid.collectionView.reloadItems(at: [IndexPath(item: badIndex, section: 0)])
    grid.layoutSubtreeIfNeeded()
    let reloadedFailure = try #require(grid.collectionView.item(at: IndexPath(item: badIndex, section: 0)) as? GridPhotoItem)
    #expect(reloadedFailure.view.accessibilityLabel()?.contains("unavailable") == true)
    grid.collectionView.reloadItems(at: [IndexPath(item: goodIndex, section: 0)])
    grid.layoutSubtreeIfNeeded()
    let reloaded = try #require(grid.collectionView.item(at: IndexPath(item: goodIndex, section: 0)) as? GridPhotoItem)
    #expect(reloaded.tileLayer?.contents != nil)
    #expect(reloaded.view.accessibilityLabel() == "Visible.jpg")
    grid.stopThumbnails()
}

@Test @MainActor func gridScrollStartsThumbnailForNewVisibleCell() async throws {
    _ = NSApplication.shared
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: URL(fileURLWithPath: "/tmp/grid-scroll-thumbnails"))
    let entries = (0..<500).map { FolderEntry(url: root.url.appendingPathComponent(String(format: "%04d.jpg", $0)), root: root) }
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: root.url, generation: 1),
        entries: entries, isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    let log = GridThumbnailRequestLog()
    grid.thumbnailLoader = { entry, _, edge, _ in
        await log.add(entry.itemID)
        return thumbnailRequest(entry, edge: edge, revision: 1)
    }
    grid.display(snapshot, selectedItemID: nil)
    grid.setThumbnailsActive(true)
    grid.layoutSubtreeIfNeeded()
    let last = try #require(entries.last)
    #expect(!(await log.contains(last.itemID)))
    let clip = try #require(grid.collectionView.enclosingScrollView?.contentView)
    clip.setBoundsOrigin(NSPoint(x: 0, y: max(0, grid.collectionView.bounds.height - clip.bounds.height)))
    grid.collectionView.enclosingScrollView?.reflectScrolledClipView(clip)
    await log.waitFor(last.itemID)
    #expect(await log.contains(last.itemID))
    grid.stopThumbnails()
}

@Test @MainActor func gridOffscreenFailureAppearsWhenScrolledIntoView() async throws {
    _ = NSApplication.shared
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: URL(fileURLWithPath: "/tmp/grid-offscreen-failure"))
    let entries = (0..<100).map { FolderEntry(url: root.url.appendingPathComponent("\($0).jpg"), root: root) }
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: root.url, generation: 1),
        entries: entries, isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.thumbnailLoader = { _, _, _, _ in throw ImageLoadError(.corruptImage) }
    grid.display(snapshot, selectedItemID: nil)
    grid.setThumbnailsActive(true)
    grid.layoutSubtreeIfNeeded()
    let attributes = try #require(grid.collectionView.collectionViewLayout?.layoutAttributesForElements(in: grid.collectionView.visibleRect))
    let lastVisibleIndex = attributes.compactMap { $0.indexPath?.item }.max()
    let lastVisible = try #require(lastVisibleIndex)
    let target = lastVisible + 4
    #expect(grid.collectionView.item(at: IndexPath(item: target, section: 0)) == nil)
    await grid.waitForThumbnail(at: target)
    grid.collectionView.scrollToItems(at: [IndexPath(item: target, section: 0)], scrollPosition: .centeredVertically)
    grid.layoutSubtreeIfNeeded()
    await grid.waitForThumbnail(at: target)
    let cell = try #require(grid.collectionView.item(at: IndexPath(item: target, section: 0)) as? GridPhotoItem)
    #expect(cell.representedItemID == entries[target].itemID)
    #expect(cell.view.accessibilityLabel()?.contains("unavailable") == true)
    grid.stopThumbnails()
}

@Test @MainActor func gridRootReplacementRejectsLateSameFilenamePixels() async throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/grid-root-replacement")
    let oldRoot = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let newRoot = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let old = FolderEntry(url: folder.appendingPathComponent("Same.jpg"), root: oldRoot)
    let fresh = FolderEntry(url: folder.appendingPathComponent("Same.jpg"), root: newRoot)
    let first = FolderSnapshot(version: .init(rootID: oldRoot.id, folder: folder, generation: 1),
        entries: [old], isComplete: true)
    let second = FolderSnapshot(version: .init(rootID: newRoot.id, folder: folder, generation: 2),
        entries: [fresh], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    let port = HeldGridImagePort()
    grid.thumbnailLoader = { entry, rootID, edge, _ in
        await port.load(entry, edge: edge, revision: rootID == oldRoot.id ? 1 : 2)
    }
    grid.display(first, selectedItemID: nil)
    grid.setThumbnailsActive(true)
    grid.layoutSubtreeIfNeeded()
    await port.waitFor(old.itemID)
    #expect(await port.has(old.itemID))
    grid.display(second, selectedItemID: nil)
    await port.waitFor(fresh.itemID)
    #expect(await port.has(fresh.itemID))
    await port.release(fresh.itemID)
    await grid.waitForThumbnail(at: 0)
    let cell = try #require(grid.collectionView.item(at: IndexPath(item: 0, section: 0)) as? GridPhotoItem)
    #expect(cell.representedItemID == fresh.itemID)
    let freshImage = try #require(cell.tileLayer?.contents) as! CGImage
    let freshPixels = try #require(freshImage.dataProvider?.data as Data?)
    await port.release(old.itemID) // The port intentionally ignores cancellation.
    await Task.yield()
    #expect(cell.representedItemID == fresh.itemID)
    let lateImage = try #require(cell.tileLayer?.contents) as! CGImage
    #expect(lateImage.dataProvider?.data as Data? == freshPixels)
    #expect(cell.view.accessibilityLabel() == "Same.jpg")
    grid.stopThumbnails()
}
