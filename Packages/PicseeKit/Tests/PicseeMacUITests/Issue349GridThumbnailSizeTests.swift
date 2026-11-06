import AppKit
import ImageIO
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
@testable import PicseeMacUI

@MainActor private final class Issue349GridScene {
    let store: InMemoryDisplayPreferencesStore
    let shell: GridShellView
    let grid: GridBrowserView
    let window: NSWindow
    let snapshot: FolderSnapshot
    var entries: [FolderEntry] { snapshot.entries }

    init(width: CGFloat = 1280, size: Double = 220, sidebar: Bool = true, count: Int = 48,
         appearance: NSAppearance.Name = .aqua, scroller: NSScroller.Style = .overlay,
         folder: URL = URL(fileURLWithPath: "/tmp/issue349-grid"), names: [String]? = nil) throws {
        _ = NSApplication.shared
        var preferences = DisplayPreferences()
        preferences.thumbnailSize = size
        preferences.gridSidebarVisible = sidebar
        store = InMemoryDisplayPreferencesStore(preferences)
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 800), preferencesStore: store)
        shell.appearance = NSAppearance(named: appearance)
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        grid.autoresizingMask = [.width, .height]
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        let scroll = try #require(grid.collectionView.enclosingScrollView)
        scroll.scrollerStyle = scroller
        scroll.tile()
        let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
        let filenames = names ?? (0..<count).map { index in
            index.isMultiple(of: 2) ? "\(index)-这是一个用于确认单行文件名正确截断的非常长的中文照片名称.jpg"
                : "\(index)-An-extremely-long-English-photo-filename-that-must-truncate-at-every-size.jpg"
        }
        .map { name in
            name.replacingOccurrences(of: ".jpg", with: String(repeating:
                name.contains("这是") ? "-用于确认所有宽度下截断" : "-long-filename-pressure",
                count: name.contains("这是") ? 3 : 6) + ".jpg")
        }
        snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
            entries: filenames.map { FolderEntry(url: folder.appendingPathComponent($0), root: root) }, isComplete: true)
        grid.display(snapshot, selectedItemID: nil)
        grid.activate()
        settle()
    }
    var scroll: NSScrollView { grid.collectionView.enclosingScrollView! }
    var layout: NSCollectionViewFlowLayout { grid.collectionView.collectionViewLayout as! NSCollectionViewFlowLayout }
    func settle() {
        shell.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        for item in grid.collectionView.visibleItems() { item.view.layoutSubtreeIfNeeded() }
    }
    func set(_ size: Double) { store.value.thumbnailSize = size; settle() }
    func item(_ index: Int) throws -> GridPhotoItem {
        try #require(grid.collectionView.item(at: IndexPath(item: index, section: 0)) as? GridPhotoItem)
    }
    func cellFrame(_ index: Int) throws -> NSRect {
        try #require(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
    }
    func columns() throws -> Int {
        let y = try cellFrame(0).minY
        return try entries.indices.filter { abs(try cellFrame($0).minY - y) < 0.01 }.count
    }
    func close() {
        grid.stopThumbnails()
        grid.removeFromSuperview()
        window.contentView = nil
        window.close()
    }
}

/// The pinned root variants deliberately leave their multiplier readable independently of PinnedDesign's CSS math.
private func issue349PinnedHeight(_ design: PinnedDesign, width: Double, size: Double) throws -> Double {
    let baseline = try design.length(".thumbnail-wrap", "height", viewport: width)
    let defaultSize = try design.length(":root", "--thumbnail-size-default", viewport: width)
    if size != defaultSize {
        let variant = "[data-thumbnail-size=\"\(Int(size))\"]"
        let bound = size < defaultSize ? "min" : "max"
        #expect(try design.exactDeclaration(variant, "--thumbnail-height")
            == "calc(var(--thumbnail-height-base) * var(--thumbnail-scale-\(bound)))")
        #expect(try design.length(variant, "--thumb-min", viewport: width) == size)
        #expect(try design.exactDeclaration(":root", "--thumbnail-scale-\(bound)")
            == "calc(\(Int(size)) / \(Int(defaultSize)))")
    }
    return width <= 720 ? baseline : baseline * size / defaultSize
}

private func issue349PinnedHorizontalInsets(_ design: PinnedDesign, width: Double) throws -> (left: Double, right: Double) {
    // Harness correction after RED: edges(padding) refuses the unrelated contextual padding-top rule.
    // Read the pinned shorthand plus its individual responsive horizontal overrides instead.
    let shorthand = try design.declaration(".grid-scroll", "padding", viewport: width).split(separator: " ")
    try #require((1...4).contains(shorthand.count))
    let horizontal = try design.lengthValue(String(shorthand[shorthand.count == 1 ? 0 : 1]), viewport: width)
    let left = (try? design.length(".grid-scroll", "padding-left", viewport: width)) ?? horizontal
    let right = (try? design.length(".grid-scroll", "padding-right", viewport: width)) ?? horizontal
    return (left, right)
}

@Suite(.serialized) struct Issue349GridThumbnailSizeTests {
    @Test @MainActor func issue349GridDetachedResizeKeepsCurrentWhileAwaitingWindowAttachment() throws {
        let scene = try Issue349GridScene(count: 96)
        defer { scene.close() }
        let ids = scene.entries.map(\.itemID)
        var selection = BrowserSelection()
        selection.click(ids[83], in: ids)
        scene.grid.display(scene.snapshot, selection: selection)
        scene.grid.restoreContentOffset(.zero)
        // A view can receive preferences between removal from one host and attachment to another.
        scene.grid.removeFromSuperview()
        #expect(scene.grid.window == nil)
        scene.grid.displayOptions = GridDisplayOptions(thumbnailSize: 280)
        scene.grid.layoutSubtreeIfNeeded()
        scene.grid.collectionView.layoutSubtreeIfNeeded()
        #expect(scene.grid.selection == selection)
        #expect(scene.grid.currentItemID == ids[83])
        #expect(scene.grid.contentOffset.y > 0, "detached resize still reveals the conserved Current Item")
    }

    /// FIRST UI RED: assertions inspect attached rendered cells/tiles, not production geometry inputs.
    @Test @MainActor func issue349GridRenderedFramesFollowPinnedSizesAtEveryBreakpoint() throws {
        let widths: [CGFloat] = [1601, 1600, 1599, 1280, 1051, 1050, 1049, 721, 720, 719, 481, 480, 479]
        for (page, appearance) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
            let design = try PinnedDesign.page(page)
            for width in widths {
                for size in [140.0, 220, 280] {
                    let scene = try Issue349GridScene(width: width, size: size, appearance: appearance)
                    defer { scene.close() }
                    let cell = try scene.item(0)
                    let tile = try #require(cell.tileLayer)
                    let expectedHeight = try issue349PinnedHeight(design, width: width, size: size)
                    #expect(abs(tile.frame.height - expectedHeight) < 0.02,
                        "\(page) width\(width) size\(size): rendered\(tile.frame.height) expected\(expectedHeight)")
                    let insets = try issue349PinnedHorizontalInsets(design, width: width)
                    let gaps = try design.edges(".photo-grid", "gap", viewport: width)
                    let track = width <= 720
                        ? try design.length(":root", "--thumbnail-track-compact", viewport: width) : size
                    let available = scene.scroll.contentSize.width - insets.left - insets.right
                    let columns = width <= 480 ? 1 : max(1, Int(floor((available + gaps.right) / (track + gaps.right))))
                    #expect(try scene.columns() == columns, "\(page) width\(width) size\(size)")
                    let expectedWidth = (available - CGFloat(columns - 1) * gaps.right) / CGFloat(columns)
                    #expect(abs(cell.view.frame.width - expectedWidth) < 0.02)
                    #expect(abs(tile.frame.width - (cell.view.bounds.width - 8)) < 0.02)
                    let first = try scene.cellFrame(0), secondRow = try scene.cellFrame(columns)
                    #expect(abs(secondRow.minY - first.minY - (expectedHeight + 36 + gaps.top)) < 0.02)
                    for index in [0, 1] {
                        let photo = try scene.item(index)
                        let label = try #require(photo.view.subviews.compactMap { $0 as? NSTextField }
                            .first { $0.stringValue == photo.filename })
                        #expect(label.maximumNumberOfLines == 1 && label.lineBreakMode == .byTruncatingTail)
                        #expect(photo.view.bounds.contains(label.frame))
                        let ideal = (label.stringValue as NSString).size(withAttributes: [
                            .font: label.font ?? NSFont.systemFont(ofSize: 13)])
                        #expect(ideal.width > label.frame.width, "long name pressure at \(width)/\(size)/\(page)")
                        #expect(photo.filename.lengthOfBytes(using: .utf8) <= 255, "realistic filename length")
                    }
                }
            }
        }
    }

    @Test @MainActor func issue349GridColumnsRespectExactThresholdAndScrollerWidth() throws {
        let design = try PinnedDesign.page("grid-light")
        // Solve each CSS media region independently, then assert just below, at, and above each feasible boundary.
        // Harness correction after RED: NSWindow rounds fractional initial content widths to backing pixels;
        // ±1pt expresses actual native window sizes and still tests both sides of every feasible threshold.
        for size in [140.0, 220, 280] {
            for n in 2...9 {
                for (inset, gap, minimum, maximum) in [(16.0, 12.0, 720.0, 1050.0),
                    (24, 16, 1050, 1600), (32, 22, 1599, 3000)] {
                    let threshold = Double(n) * size + Double(n - 1) * gap + 2 * inset
                    guard threshold > minimum + 1, threshold < maximum - 1 else { continue }
                    for delta in [-1.0, 0, 1] {
                        let width = threshold + delta
                        let scene = try Issue349GridScene(width: width, size: size, sidebar: false)
                        defer { scene.close() }
                        #expect(abs(scene.shell.bounds.width - width) < 0.01, "the oracle uses the actual native viewport")
                        let cssGap = try design.edges(".photo-grid", "gap", viewport: width).right
                        #expect(cssGap == gap)
                        #expect(try scene.columns() == (delta < 0 ? n - 1 : n), "size\(size) n\(n) delta\(delta)")
                        let last = try scene.cellFrame((delta < 0 ? n - 1 : n) - 1)
                        #expect(last.maxX <= scene.scroll.contentSize.width - inset + 0.02)
                    }
                }
            }
        }
        for style: NSScroller.Style in [.overlay, .legacy] {
            for count in [2, 48] {
                for width: CGFloat in [1280, 1050, 721] {
                    let scene = try Issue349GridScene(width: width, size: 280, count: count, scroller: style)
                    defer { scene.close() }
                    scene.scroll.autohidesScrollers = true
                    scene.scroll.hasVerticalScroller = true
                    scene.scroll.tile()
                    scene.settle()
                    scene.scroll.reflectScrolledClipView(scene.scroll.contentView)
                    let scroller = try #require(scene.scroll.verticalScroller)
                    #expect(scroller.isHidden == (count == 2), "actual scrollbar visibility")
                    let lastCell = try scene.cellFrame(count - 1)
                    #expect(count == 48 ? lastCell.maxY > scene.scroll.contentSize.height
                        : lastCell.maxY < scene.scroll.contentSize.height, "actual overflow/short content pressure")
                    let tile = try #require(try scene.item(0).tileLayer)
                    let expectedHeight = try issue349PinnedHeight(design, width: width, size: 280)
                    #expect(abs(tile.frame.height - expectedHeight) < 0.02)
                    let insets = try issue349PinnedHorizontalInsets(design, width: width)
                    let gap = try design.edges(".photo-grid", "gap", viewport: width).right
                    let available = scene.scroll.contentSize.width - insets.left - insets.right
                    let columns = max(1, Int(floor((available + gap) / (280 + gap))))
                    #expect(try scene.columns() == min(count, columns))
                    let first = try scene.item(0)
                    #expect(abs(first.view.frame.width - (available - CGFloat(columns - 1) * gap) / CGFloat(columns)) < 0.02)
                    #expect(scene.scroll.scrollerStyle == style)
                }
            }
        }
    }

    @Test @MainActor func issue349GridNamesAndShellFramesStayStableAcrossSizeChanges() throws {
        for (page, appearance) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
            let design = try PinnedDesign.page(page)
            #expect(try design.declaration(".photo-name", "white-space", viewport: 1280) == "nowrap")
            #expect(try design.declaration(".photo-name", "text-overflow", viewport: 1280) == "ellipsis")
            for width: CGFloat in [1280, 720, 480] {
                let scene = try Issue349GridScene(width: width, appearance: appearance)
                defer { scene.close() }
                let sidebar = scene.shell.sidebar.frame, footer = scene.shell.footer.frame
                var compactFrame: NSRect?
                for size in [140.0, 220, 280, 140] {
                    scene.set(size)
                    #expect(scene.shell.sidebar.frame == sidebar)
                    #expect(scene.shell.footer.frame == footer)
                    let footerHeight = try design.length(".grid-bottom-bar", "height", viewport: width)
                    #expect(abs(footer.height - footerHeight) < 0.02)
                    #expect(abs(footer.minY - scene.shell.bounds.minY) < 0.02)
                    for index in [0, 1] {
                        let item = try scene.item(index)
                        let label = try #require(item.view.subviews.compactMap { $0 as? NSTextField }
                            .first { $0.stringValue == item.filename })
                        #expect(label.maximumNumberOfLines == 1 && label.lineBreakMode == .byTruncatingTail)
                        #expect(item.view.bounds.contains(label.frame))
                        let ideal = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)])
                        #expect(ideal.width > label.frame.width, "\(item.filename) really exercises truncation")
                    }
                    if width <= 720 {
                        let frame = try scene.cellFrame(0)
                        if let compactFrame { #expect(frame == compactFrame) }
                        compactFrame = frame
                    }
                }
            }
        }
    }

    @Test @MainActor func issue349GridSizeChangeRevealsCurrentAndConservesSelection() throws {
        let scene = try Issue349GridScene(count: 96)
        defer { scene.close() }
        let ids = scene.entries.map(\.itemID)
        var selection = BrowserSelection()
        selection.click(ids[2], in: ids)
        selection.click(ids[83], modifier: .command, in: ids)
        scene.grid.display(scene.snapshot, selection: selection)
        scene.settle()
        for size in [280.0, 140, 220, 260, 150] {
            scene.grid.restoreContentOffset(.zero)
            scene.set(size)
            #expect(scene.grid.currentItemID == ids[83])
            #expect(scene.grid.selection == selection)
            #expect(scene.grid.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0), IndexPath(item: 83, section: 0)])
            let cell = try scene.cellFrame(83)
            let clip = scene.scroll.contentView.documentVisibleRect
            let inset = scene.scroll.contentInsets
            #expect(cell.minY >= clip.minY + inset.top - 0.02)
            #expect(cell.maxY <= clip.maxY - inset.bottom + 0.02,
                "size\(size): current\(cell) visible\(clip) insets\(inset)")
            let offset = scene.grid.contentOffset
            scene.set(size)
            #expect(scene.grid.contentOffset == offset, "equal size is idempotent")
        }
    }

    @Test(.timeLimit(.minutes(2))) @MainActor func issue349GridRealImageIOResultsCoverNewRenderedSize() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("issue349-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sharp.png")
        let context = try #require(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8,
            bytesPerRow: 8192, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let scene = try Issue349GridScene(size: 140, sidebar: false, folder: folder, names: ["sharp.png"])
        defer { scene.close() }
        let pipeline = ImageIOPipeline()
        let root = ItemIdentityRoot(id: scene.snapshot.version.rootID, url: folder)
        scene.grid.thumbnailLoader = { entry, _, coverage, priority in
            let request = try await pipeline.request(for: entry.url, covering: coverage, identityRoot: root)
            let image = try await pipeline.image(for: ImageDecodeRequest(fileURL: entry.url,
                maximumPixelSize: request.maximumPixelSize, renderKey: request.renderKey,
                priority: priority, identityRoot: root))
            return (request, image)
        }
        scene.grid.setThumbnailsActive(true)
        var edges: [Int] = []
        for size in [140.0, 280, 140, 220] {
            scene.set(size)
            await scene.grid.waitForThumbnail(at: 0)
            scene.settle()
            let cell = try scene.item(0)
            let tile = try #require(cell.tileLayer)
            let contents = try #require(tile.contents)
            try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
            let image = contents as! CGImage
            let scale = scene.window.backingScaleFactor
            #expect(CGFloat(image.width) >= ceil(tile.frame.width * scale))
            #expect(CGFloat(image.height) >= ceil(tile.frame.height * scale))
            #expect(cell.representedItemID == scene.entries[0].itemID)
            edges.append(image.width)
        }
        #expect(edges[1] > edges[0], "larger rendered tiles install sharper decoded pixels")
    }
}
