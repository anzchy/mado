import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
@testable import PicseeMacUI

/// #114 / P3-11 WI-2: the grid applies Thumbnail Size, Show File Names and Fill/Fit (grid-display.html).
@MainActor private final class Issue114GridFixture {
    let grid: GridBrowserView
    let shell: GridShellView
    let window: NSWindow
    let entries: [FolderEntry]
    let rootID: AccessRootID
    let folder: URL
    init(width: CGFloat, sidebar: Bool = true, count: Int = 12, options: GridDisplayOptions? = nil,
        loader: GridLoader? = nil) throws {
        _ = NSApplication.shared
        var preferences = DisplayPreferences()
        preferences.gridSidebarVisible = sidebar
        // The shell gives an attached grid the stored options, so a fixture's options live in the store too.
        if let options {
            preferences.thumbnailSize = options.thumbnailSize
            preferences.showFileNames = options.showFileNames
            preferences.thumbnailFit = options.fit
        }
        let store = InMemoryDisplayPreferencesStore(preferences)
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 772), preferencesStore: store)
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        grid.autoresizingMask = [.width, .height]
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                          styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        let scrollView = try #require(grid.collectionView.enclosingScrollView)
        scrollView.scrollerStyle = .overlay
        scrollView.tile()
        if let options { grid.displayOptions = options }
        if let loader { grid.thumbnailLoader = loader }
        let url = URL(fileURLWithPath: "/tmp/picsee-grid-114")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: url)
        let made = (0..<count).map { FolderEntry(url: url.appendingPathComponent("IMG_\($0).jpg"), root: root) }
        folder = url; rootID = root.id; entries = made
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: url, generation: 1),
            entries: made, isComplete: true), selectedItemID: nil)
        grid.activate()
        settle()
    }
    typealias GridLoader = @Sendable (FolderEntry, AccessRootID, ThumbnailCoverage, DecodePriority) async throws
        -> (ImageDecodeRequest, DecodedImage)
    func settle() {
        shell.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        for item in grid.collectionView.visibleItems() { item.view.layoutSubtreeIfNeeded() }
    }
    func set(_ options: GridDisplayOptions) {
        grid.displayOptions = options
        settle()
    }
    /// Stops thumbnails and detaches the views, so nothing in this window outlives the test (#316 f89a0cab).
    func close() {
        grid.stopThumbnails()
        grid.removeFromSuperview()
        window.contentView = nil
        window.close()
    }
    var layout: NSCollectionViewFlowLayout { grid.collectionView.collectionViewLayout as! NSCollectionViewFlowLayout }
    var columns: Int {
        guard let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) else { return 0 }
        return (0..<entries.count).filter { index in
            layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)).map {
                abs($0.frame.minY - first.frame.minY) < 0.5 } ?? false
        }.count
    }
    func item(_ index: Int) throws -> GridPhotoItem {
        try #require(grid.collectionView.item(at: IndexPath(item: index, section: 0)) as? GridPhotoItem)
    }
    var visiblePhotoItems: [GridPhotoItem] { grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem } }
    var rowPitch: CGFloat {
        let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame
        let next = layout.layoutAttributesForItem(at: IndexPath(item: columns, section: 0))!.frame
        return next.minY - first.minY
    }
}

private func issue114Pixel() -> CGImage {
    let data = Data([90, 90, 90, 255])
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private actor Issue114LoaderLog {
    private(set) var requests: [(ItemID, ThumbnailCoverage)] = []
    func add(_ id: ItemID, _ coverage: ThumbnailCoverage) { requests.append((id, coverage)) }
    var count: Int { requests.count }
    func last(_ id: ItemID) -> ThumbnailCoverage? { requests.last { $0.0 == id }?.1 }
    func ids(after index: Int) -> [ItemID] { requests.dropFirst(index).map(\.0) }
}

private func issue114Loader(_ log: Issue114LoaderLog) -> Issue114GridFixture.GridLoader {
    { entry, _, coverage, _ in
        await log.add(entry.itemID, coverage)
        let edge = coverage.fallbackEdge
        let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 1, modificationDate: nil),
            maximumPixelSize: edge)
        let request = ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key)
        return (request, DecodedImage(image: issue114Pixel(), sourcePixelSize: CGSize(width: 1, height: 1),
            revision: key.revision, itemID: entry.itemID))
    }
}

private let issue114Sizes: [Double] = Array(stride(from: 140.0, through: 280.0, by: 10.0))

/// One #114 grid window at a time: other suites still run concurrently while the loops below yield (#316 f89a0cab).
@Suite(.serialized) struct Issue114GridDisplayOptionsTests {
    @Test @MainActor func issue114GridDefaultOptionsMatchTodayAtParityViewports() async throws {
        #expect(GridDisplayOptions() == GridDisplayOptions(DisplayPreferences()))
        for width: CGFloat in [1280, 1050, 800, 720, 480] {
            let untouched = try Issue114GridFixture(width: width)
            let explicit = try Issue114GridFixture(width: width, options: GridDisplayOptions(DisplayPreferences()))
            defer { untouched.close(); explicit.close() }
            #expect(untouched.grid.displayOptions == GridDisplayOptions(DisplayPreferences()))
            #expect(untouched.layout.itemSize == explicit.layout.itemSize, "item size at \(width)")
            #expect(untouched.layout.sectionInset.left == explicit.layout.sectionInset.left
                && untouched.layout.sectionInset.top == explicit.layout.sectionInset.top, "inset at \(width)")
            #expect(untouched.layout.minimumInteritemSpacing == explicit.layout.minimumInteritemSpacing
                && untouched.layout.minimumLineSpacing == explicit.layout.minimumLineSpacing, "spacing at \(width)")
            #expect(untouched.columns == explicit.columns, "columns at \(width)")
            if width == 1280 {
                #expect(abs(explicit.layout.itemSize.height - 224.16) < 0.01)
                #expect(explicit.columns == 4)
                let tile = try #require(try explicit.item(0).tileLayer)
                #expect(abs(tile.frame.height - 188.16) < 0.01, "1280 tile \(tile.frame)")
            }
            await Task.yield()
        }
    }

    @Test @MainActor func issue114GridColumnsAt1280FollowCSSFormula() async throws {
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false)
        defer { fixture.close() }
        #expect(abs(fixture.grid.collectionView.enclosingScrollView!.contentSize.width - 2 * 24 - 1232) < 0.5)
        let cases: [(size: Double, columns: Int)] = [(140, 8), (150, 7), (220, 5), (240, 4), (280, 4)]
        for item in cases {
            fixture.set(GridDisplayOptions(thumbnailSize: item.size))
            #expect(fixture.columns == item.columns, "columns at size \(item.size)")
            let width = fixture.layout.itemSize.width
            if item.size == 140 { #expect(width >= 140 - 0.01 && width <= 140, "cell at 140: \(width)") }
            if item.size == 220 { #expect(abs(width - 233.6) < 0.01, "cell at 220: \(width)") }
            await Task.yield()
        }
    }

    @Test @MainActor func issue114GridColumnsMonotonicAndFormulaAcrossWidths() async throws {
        for width: CGFloat in [721, 800, 1050, 1051, 1280, 1599, 1600, 1920] {
            for sidebar in [true, false] {
                let fixture = try Issue114GridFixture(width: width, sidebar: sidebar, count: 24)
                defer { fixture.close() }
                let available = fixture.grid.collectionView.enclosingScrollView!.contentSize.width
                    - 2 * fixture.layout.sectionInset.left
                let gap = fixture.layout.minimumInteritemSpacing
                var ascending: [Double: NSSize] = [:]
                var previous = Int.max
                var tileHeight: CGFloat?
                let label = "width \(width) sidebar \(sidebar)"
                for size in issue114Sizes {
                    fixture.set(GridDisplayOptions(thumbnailSize: size))
                    let columns = fixture.columns
                    let formula = max(1, Int((available + gap) / (CGFloat(size) + gap)))
                    #expect(columns >= 1 && columns == formula, "\(label) size \(size): \(columns) vs \(formula)")
                    #expect(columns <= previous, "\(label) non-increasing at \(size)")
                    if columns > 1 { #expect(fixture.layout.itemSize.width >= CGFloat(size) - 0.01, "\(label) cell ≥ \(size)") }
                    let height = try #require(try fixture.item(0).tileLayer).frame.height
                    if let tileHeight { #expect(height == tileHeight, "\(label) tile height constant at \(size)") }
                    tileHeight = height
                    previous = columns
                    ascending[size] = fixture.layout.itemSize
                    await Task.yield()
                }
                for size in issue114Sizes.reversed() {
                    fixture.set(GridDisplayOptions(thumbnailSize: size))
                    #expect(fixture.layout.itemSize == ascending[size], "\(label) path-independent at \(size)")
                    await Task.yield()
                }
            }
        }
    }

    @Test @MainActor func issue114GridNarrowViewportsIgnoreSize() async throws {
        for width: CGFloat in [481, 600, 720] {
            let fixture = try Issue114GridFixture(width: width)
            defer { fixture.close() }
            fixture.set(GridDisplayOptions(thumbnailSize: 220))
            let reference = (fixture.layout.itemSize, fixture.columns)
            if width == 720 { #expect(reference.1 == 3) }
            for size in issue114Sizes {
                fixture.set(GridDisplayOptions(thumbnailSize: size))
                #expect(fixture.layout.itemSize == reference.0 && fixture.columns == reference.1, "width \(width) size \(size)")
                await Task.yield()
            }
        }
        for width: CGFloat in [300, 400, 480] {
            let fixture = try Issue114GridFixture(width: width, sidebar: false)
            defer { fixture.close() }
            for size in issue114Sizes {
                fixture.set(GridDisplayOptions(thumbnailSize: size))
                #expect(fixture.columns == 1, "width \(width) size \(size)")
                await Task.yield()
            }
        }
    }

    @Test @MainActor func issue114GridGeometryIsPathIndependent() async throws {
        let targets = [GridDisplayOptions(thumbnailSize: 140, showFileNames: true, fit: .fill),
                       GridDisplayOptions(thumbnailSize: 280, showFileNames: false, fit: .fit),
                       GridDisplayOptions(thumbnailSize: 170, showFileNames: false, fit: .fill)]
        for target in targets {
            let direct = try Issue114GridFixture(width: 1280, sidebar: false, options: target)
            let stepped = try Issue114GridFixture(width: 1280, sidebar: false)
            defer { direct.close(); stepped.close() }
            for size in [220.0, 260.0] { stepped.set(GridDisplayOptions(thumbnailSize: size)) }
            stepped.set(target)
            let a = try direct.item(0), b = try stepped.item(0)
            #expect(direct.layout.itemSize == stepped.layout.itemSize, "\(target)")
            #expect(direct.columns == stepped.columns, "\(target)")
            #expect(a.tileLayer?.frame == b.tileLayer?.frame, "\(target)")
            #expect(a.isNameVisible == target.showFileNames && b.isNameVisible == target.showFileNames, "\(target)")
            let gravity: CALayerContentsGravity = target.fit == .fit ? .resizeAspect : .resizeAspectFill
            #expect(a.tileLayer?.contentsGravity == gravity && b.tileLayer?.contentsGravity == gravity, "\(target)")
            await Task.yield()
        }
    }

    @Test @MainActor func issue114GridNamesToggleRoundTripsFrames() throws {
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false)
        defer { fixture.close() }
        fixture.grid.setCurrentItemID(fixture.entries[0].itemID)
        fixture.set(GridDisplayOptions(thumbnailSize: 220))
        struct Snapshot: Equatable { let item: NSSize; let tile: NSRect; let ring: NSRect; let names: Bool; let pitch: CGFloat }
        func snapshot() throws -> Snapshot {
            let item = try fixture.item(0)
            return Snapshot(item: fixture.layout.itemSize, tile: try #require(item.tileLayer).frame,
                ring: item.currentRingLayer.frame, names: item.isNameVisible, pitch: fixture.rowPitch)
        }
        func near(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
                && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        let on = try snapshot()
        #expect(abs(on.item.height - 224.16) < 0.01)
        #expect(near(on.tile, NSRect(x: 4, y: 32, width: 225.6, height: 188.16)), "names on tile \(on.tile)")
        #expect(on.names)
        #expect(abs(on.pitch - 242.16) < 0.01)
        fixture.set(GridDisplayOptions(thumbnailSize: 220, showFileNames: false))
        let off = try snapshot()
        #expect(abs(off.item.height - 196.16) < 0.01)
        #expect(near(off.tile, NSRect(x: 4, y: 4, width: 225.6, height: 188.16)), "names off tile \(off.tile)")
        #expect(!off.names)
        #expect(abs(off.pitch - 214.16) < 0.01)
        #expect(near(off.ring, off.tile.insetBy(dx: -4, dy: -4)), "ring follows tile \(off.ring)")
        #expect(try fixture.item(0).isCurrent)
        fixture.set(GridDisplayOptions(thumbnailSize: 220, showFileNames: true))
        #expect(try snapshot() == on)
    }

    @Test @MainActor func issue114GridFitGravityAppliesToVisibleAndReusedItems() throws {
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false)
        defer { fixture.close() }
        fixture.set(GridDisplayOptions(fit: .fit))
        #expect(!fixture.visiblePhotoItems.isEmpty)
        for item in fixture.visiblePhotoItems { #expect(item.tileLayer?.contentsGravity == .resizeAspect, "\(item.filename)") }
        let root = ItemIdentityRoot(id: fixture.rootID, url: fixture.folder)
        let more = (0..<40).map { FolderEntry(url: fixture.folder.appendingPathComponent("MORE_\($0).jpg"), root: root) }
        fixture.grid.display(FolderSnapshot(version: .init(rootID: fixture.rootID, folder: fixture.folder, generation: 2),
            entries: more, isComplete: true), selectedItemID: nil)
        fixture.settle()
        fixture.grid.scrollTo(more[39].itemID)
        fixture.settle()
        let visible = fixture.visiblePhotoItems
        #expect(visible.contains { $0.representedItemID == more[39].itemID })
        for item in visible { #expect(item.tileLayer?.contentsGravity == .resizeAspect, "reused \(item.filename)") }
        fixture.set(GridDisplayOptions(fit: .fill))
        for item in fixture.visiblePhotoItems { #expect(item.tileLayer?.contentsGravity == .resizeAspectFill, "\(item.filename)") }
    }

    @Test(.timeLimit(.minutes(2))) @MainActor func issue114GridCoverageMatchesRenderedTileWithNamesHidden() async throws {
        let log = Issue114LoaderLog()
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false, loader: issue114Loader(log))
        defer { fixture.close() }
        fixture.set(GridDisplayOptions(thumbnailSize: 140, showFileNames: false))
        fixture.grid.setThumbnailsActive(true)
        fixture.settle()
        let id = fixture.entries[0].itemID
        await waitUntil { await log.last(id) != nil }
        let coverage = try #require(await log.last(id))
        let tile = try #require(try fixture.item(0).tileLayer).frame
        let scale = fixture.window.backingScaleFactor
        #expect(try !fixture.item(0).isNameVisible, "names hidden")
        #expect(abs(fixture.layout.itemSize.height - 196.16) < 0.01, "item height without the name row")
        #expect(abs(tile.height - 188.16) < 0.01, "tile \(tile)")
        #expect(abs(coverage.width - tile.width * scale) < 0.01, "coverage \(coverage) tile \(tile)")
        #expect(abs(coverage.height - tile.height * scale) < 0.01, "coverage \(coverage) tile \(tile)")
    }

    @Test(.timeLimit(.minutes(2))) @MainActor func issue114GridEqualOptionsAndNameToggleCauseNoNewRequests() async throws {
        let log = Issue114LoaderLog()
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false, loader: issue114Loader(log))
        defer { fixture.close() }
        fixture.grid.setThumbnailsActive(true)
        fixture.settle()
        for index in 0..<fixture.entries.count { await fixture.grid.waitForThumbnail(at: index) }
        let before = await log.count
        let itemSize = fixture.layout.itemSize
        let token = try fixture.item(0).thumbnailToken
        for _ in 0..<2 { fixture.set(GridDisplayOptions()) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.count == before)
        #expect(fixture.layout.itemSize == itemSize)
        #expect(try fixture.item(0).thumbnailToken == token)
        fixture.set(GridDisplayOptions(showFileNames: false))
        #expect(try !fixture.item(0).isNameVisible, "names hidden")
        fixture.set(GridDisplayOptions(showFileNames: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.count == before, "a name toggle keeps the tile height, so coverage is unchanged")
        for item in fixture.visiblePhotoItems { #expect(item.thumbnailHasImage, "\(item.filename) keeps its image") }
        let edge = try fixture.item(0).thumbnailPixelEdge
        fixture.set(GridDisplayOptions(thumbnailSize: 150))
        let resizedEdge = try fixture.item(0).thumbnailPixelEdge
        #expect(resizedEdge != edge, "size 150 changes the tile and its coverage")
        if resizedEdge != edge { await waitUntil { await log.count > before } }
        #expect(await log.count > before)
    }

    @Test(.timeLimit(.minutes(2))) @MainActor func issue114GridSizeIncreaseReRequestsVisibleAtNewCoverage() async throws {
        let log = Issue114LoaderLog()
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false, loader: issue114Loader(log))
        defer { fixture.close() }
        fixture.grid.setThumbnailsActive(true)
        fixture.settle()
        for index in 0..<fixture.entries.count { await fixture.grid.waitForThumbnail(at: index) }
        let visibleAt220 = Set(fixture.visiblePhotoItems.compactMap(\.representedItemID))
        #expect(!visibleAt220.isEmpty)
        let before = await log.count
        let widthAt220 = fixture.layout.itemSize.width
        fixture.set(GridDisplayOptions(thumbnailSize: 280))
        #expect(fixture.columns == 4, "280 at 1280 without sidebar")
        let scale = fixture.window.backingScaleFactor
        var expected: [ItemID: (CGFloat, CGFloat)] = [:]
        for item in fixture.visiblePhotoItems {
            guard let id = item.representedItemID, let tile = item.tileLayer?.frame else { continue }
            expected[id] = (tile.width * scale, tile.height * scale)
        }
        #expect(!expected.isEmpty)
        func matches() async -> Bool {
            for (id, size) in expected {
                guard let coverage = await log.last(id),
                      abs(coverage.width - size.0) < 0.01, abs(coverage.height - size.1) < 0.01 else { return false }
            }
            return true
        }
        if fixture.layout.itemSize.width != widthAt220 { await waitUntil { await matches() } }
        #expect(await matches(), "every visible item was requested at its rendered tile × scale")
        let renewed = await log.ids(after: before)
        #expect(renewed.contains { visibleAt220.contains($0) }, "an item visible at 220 was requested again")
    }

    @Test @MainActor func issue114GridSelectionAndCurrentSurviveOptionChanges() throws {
        let fixture = try Issue114GridFixture(width: 1280, sidebar: false)
        defer { fixture.close() }
        let ids = fixture.entries.map(\.itemID)
        var selection = BrowserSelection()
        selection.click(ids[2], in: ids)
        selection.click(ids[5], modifier: .command, in: ids)
        fixture.grid.display(FolderSnapshot(version: .init(rootID: fixture.rootID, folder: fixture.folder, generation: 1),
            entries: fixture.entries, isComplete: true), selection: selection)
        fixture.settle()
        var callbacks = 0
        fixture.grid.onCurrentChange = { _ in callbacks += 1 }
        fixture.grid.onSelectionGesture = { _, _ in callbacks += 1; return selection }
        let steps = [GridDisplayOptions(thumbnailSize: 280), GridDisplayOptions(thumbnailSize: 280, showFileNames: false),
                     GridDisplayOptions(thumbnailSize: 280, showFileNames: false, fit: .fit), GridDisplayOptions()]
        for step in steps {
            fixture.set(step)
            #expect(fixture.grid.collectionView.selectionIndexPaths
                == [IndexPath(item: 2, section: 0), IndexPath(item: 5, section: 0)], "\(step)")
            #expect(fixture.grid.currentItemID == ids[5], "\(step)")
            #expect(try fixture.item(5).isCurrent, "\(step)")
            #expect(fixture.grid.selection.selectedItemIDs == [ids[2], ids[5]], "\(step)")
        }
        #expect(callbacks == 0)
    }
}
