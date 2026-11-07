import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

private let i315Samples = ["alley", "lakeside", "hillside", "gate", "temple", "lakehouse"]
private let i315Missing = URL(fileURLWithPath: "/mado-i315-missing.jpg")

@MainActor private func i315Launch(_ urls: [String: URL]?) async throws -> FirstLaunchView {
    _ = NSApplication.shared
    let view = FirstLaunchView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
                               openButton: ViewerStateButton(frame: .zero), sampleURLs: urls)
    view.pinAccessibility()
    try await waitForSamples(view)
    return view
}

@Test @MainActor func i315WallReplacesPrintsAndStack() throws {
    let scene = StatesScene(width: 960)
    defer { scene.window.close() }
    scene.state.display(.empty)
    scene.state.layoutSubtreeIfNeeded()
    let home = try launch(in: scene)
    #expect(scene.state.textLines == ["Drop a photo folder here", "or press ⌘O"])
    #expect(scene.state.buttons.map(\.title) == ["Choose Folder…"])
    let ids = wallTestIdentifiers(in: scene.state)
    #expect(!ids.contains("first-launch.stack"), "stack still composed")
    #expect(ids.filter { $0.hasPrefix("first-launch.print") }.isEmpty, "edge prints still composed")
    let wall = try #require(wallView(home), "first-launch.wall missing")
    #expect(wall.isDescendant(of: home))
    let names = wall.layer?.sublayers?.compactMap(\.name) ?? []
    #expect(names.contains("first-launch.wall.tiles"))
    #expect(names.contains("first-launch.wall.scrim"))
}

@Test @MainActor func i315WallTilesUseOnlyBundledSamplesWithDistinctNeighbours() async throws {
    let pinned = try PinnedDesign.page("first-launch")
    let count = try pinned.childCount(tag: "img", inClass: "tiles")
    #expect(count > 0 && count % 6 == 0)
    #expect(FirstLaunchLayout.sampleNames == i315Samples)
    let names = FirstLaunchLayout.sampleNames
    func key(_ tile: FirstLaunchLayout.Tile) -> String { "\(tile.row),\(tile.column),\(tile.sample)" }
    let reference = FirstLaunchLayout.wall(in: NSSize(width: 960, height: 640)).tiles.map(key)
    let sizes = [NSSize(width: 960, height: 640)] +
        generatedSizes(seed: 0x315, count: 100, width: 360...3200, height: 480...2000)
    for size in sizes {
        let tiles = FirstLaunchLayout.wall(in: size).tiles
        #expect(tiles.count == count, "seed 0x315 size \(size)")
        var grid: [String: String] = [:]
        for tile in tiles {
            #expect(names.contains(tile.sample), "seed 0x315 size \(size) tile \(key(tile))")
            #expect(names.isEmpty || tile.sample == names[(tile.column + 2 * tile.row) % names.count],
                    "seed 0x315 size \(size) tile \(key(tile))")
            #expect(grid.updateValue(tile.sample, forKey: "\(tile.row),\(tile.column)") == nil, "duplicate cell \(key(tile))")
        }
        for tile in tiles {
            for (dr, dc) in [(0, 1), (1, 0)] {
                if let neighbour = grid["\(tile.row + dr),\(tile.column + dc)"] {
                    #expect(neighbour != tile.sample, "seed 0x315 size \(size) neighbours at \(key(tile)) +\(dr),\(dc)")
                }
            }
        }
        for name in names {
            #expect(tiles.filter { $0.sample == name }.count == count / names.count, "seed 0x315 size \(size) \(name)")
        }
        #expect(tiles.map(key) == reference, "seed 0x315 size \(size) assignment depends on size")
    }

    let scene = StatesScene()
    defer { scene.window.close() }
    let home = try launch(in: scene)
    #expect(home.sampleLoadCompleted == false, "init waited for decode")
    try await waitForSamples(home)
    #expect(home.sampleLoadCompleted)
    let containers = tileContainers(home)
    #expect(containers.count == count)
    #expect(containers.map(\.name) == FirstLaunchLayout.wall(in: NSSize(width: 960, height: 640)).tiles.map { $0.sample as String? })
    for container in containers {
        let name = try #require(container.name)
        let url = try #require(FirstLaunchView.sampleURL(name: name))
        let source = try #require(sourcePixels(url))
        #expect(!container.isHidden, "\(name) hidden")
        let image = try #require(cgImage(imageLayer(container)), "\(name) has no decoded contents")
        #expect(max(image.width, image.height) == expectedDecodedMaxSide(url), "\(name) decoded size")
        #expect((image.width > image.height) == source.landscape, "\(name) orientation")
    }
}

@Test @MainActor func i315WallHidesOnlyFailedSampleTiles() async throws {
    for failing in ["gate", "alley"] {
        var urls: [String: URL] = [:]
        for name in i315Samples { urls[name] = name == failing ? i315Missing : FirstLaunchView.sampleURL(name: name) }
        let view = try await i315Launch(urls)
        #expect(view.sampleLoadCompleted)
        let containers = tileContainers(view)
        #expect(containers.count == 60, "failing \(failing)")
        let hidden = containers.filter(\.isHidden)
        #expect(Set(hidden.compactMap(\.name)) == [failing], "failing \(failing)")
        #expect(hidden.count == 10, "failing \(failing)")
        #expect(hidden.allSatisfy { imageLayer($0)?.contents == nil }, "failing \(failing)")
        for container in containers where !container.isHidden {
            #expect(container.name != failing)
            #expect(cgImage(imageLayer(container)) != nil, "failing \(failing): \(container.name ?? "?") empty")
        }
    }
}

@Test @MainActor func i315WallShowsNoTilesWhenEverySampleFails() async throws {
    let reference = try await i315Launch(nil)
    let expectedFrames = reference.semanticViews.map(\.frame)
    let allMissing = Dictionary(uniqueKeysWithValues: i315Samples.map { ($0, i315Missing) })
    for urls in [allMissing, [:]] {
        let view = try await i315Launch(urls)
        #expect(view.sampleLoadCompleted, "\(urls.count) urls")
        let containers = tileContainers(view)
        #expect(containers.count == 60, "\(urls.count) urls")
        #expect(containers.allSatisfy { $0.isHidden }, "\(urls.count) urls")
        #expect(containers.allSatisfy { imageLayer($0)?.contents == nil }, "\(urls.count) urls")
        #expect(wallView(view) != nil)
        #expect(wallLayer("first-launch.wall.tiles", in: view) != nil)
        #expect(wallLayer("first-launch.wall.scrim", in: view) != nil)
        #expect(view.semanticViews.map(\.frame) == expectedFrames, "\(urls.count) urls")
    }
}

// MARK: - WI-2 wall geometry and tile styling (pinned page 21)

@MainActor private func i315Scene(_ size: NSSize = NSSize(width: 960, height: 640)) throws -> (StatesScene, FirstLaunchView) {
    let scene = StatesScene(width: 960)
    scene.state.display(.empty)
    try resize(scene, to: size)
    return (scene, try launch(in: scene))
}

private func i315Close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat) -> Bool { abs(a - b) <= tolerance }
private func i315Close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat) -> Bool {
    i315Close(a.x, b.x, tolerance) && i315Close(a.y, b.y, tolerance)
}
private func i315Close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
    i315Close(a.minX, b.minX, tolerance) && i315Close(a.minY, b.minY, tolerance)
        && i315Close(a.width, b.width, tolerance) && i315Close(a.height, b.height, tolerance)
}
private func i315Close(_ a: PinnedDesign.Color, _ b: PinnedDesign.Color, rgb: Double = 1.5 / 255, alpha: Double = 0.01) -> Bool {
    abs(a.red - b.red) <= rgb && abs(a.green - b.green) <= rgb && abs(a.blue - b.blue) <= rgb && abs(a.alpha - b.alpha) <= alpha
}

@Test @MainActor func i315WallFrameFillsContentBelowTitleBar() throws {
    let pinned = try PinnedDesign.page("first-launch")
    for size in [NSSize(width: 960, height: 640), NSSize(width: 800, height: 680), NSSize(width: 1440, height: 900)] {
        let (scene, home) = try i315Scene(size)
        defer { scene.window.close() }
        let titleBar = try pinned.length(":root", "--title-bar-height", viewport: size.width)
        let wall = try #require(wallView(home))
        #expect(home.bounds.size == size, "\(size)")
        #expect(i315Close(wall.convert(wall.bounds, to: home),
                          NSRect(x: 0, y: 0, width: size.width, height: size.height - titleBar), 0.001), "\(size) wall \(wall.frame)")
        #expect(wall.layer?.masksToBounds == true, "\(size)")
        let scrim = try #require(wallLayer("first-launch.wall.scrim", in: home))
        #expect(i315Close(scrim.frame, wall.bounds, 0.001), "\(size) scrim \(scrim.frame)")
    }
}

@Test func i315WallLayoutGeometryLawHoldsAcrossSizes() throws {
    let pinned = try PinnedDesign.page("first-launch")
    let selector = ".wall .tiles"
    let columns = try pinned.gridColumns(selector)
    let offset = CGFloat(try pinned.translateY(".wall .tiles>:nth-child(2n)"))
    let count = try pinned.childCount(tag: "img", inClass: "tiles")
    let seed: UInt64 = 0x3150
    let sizes = generatedSizes(seed: seed, count: 200, width: 360...3200, height: 480...2000)
        + [NSSize(width: 360, height: 680), NSSize(width: 800, height: 680)]
    let tolerance: CGFloat = 0.001
    var columnWidths: [(width: CGFloat, column: CGFloat, row: CGFloat)] = []
    for size in sizes {
        let w = Double(size.width), h = Double(size.height)
        func css(_ property: String, base: Double) throws -> CGFloat {
            CGFloat(try pinned.lengthValue(pinned.raw(selector, property, viewport: w), viewport: w, percentageBase: base))
        }
        let left = try css("left", base: w), right = try css("right", base: w)
        let top = try css("top", base: h), height = try css("height", base: h)
        let rowHeight = try css("grid-auto-rows", base: h), gap = try css("gap", base: w)
        let layout = FirstLaunchLayout.wall(in: size)
        let box = layout.box
        let context = "seed 0x3150 size \(size)"
        #expect(i315Close(box.width, size.width - left - right, tolerance), "\(context) box \(box)")
        #expect(i315Close(box.height, height, tolerance), "\(context) box \(box)")
        #expect(i315Close(box.midX, left + box.width / 2, tolerance), "\(context) box \(box)")
        #expect(i315Close(box.midX, size.width / 2, tolerance), "\(context) box \(box)")
        #expect(i315Close(box.midY, size.height - (top + height / 2), tolerance), "\(context) box \(box)")
        #expect(i315Close(box.midY, size.height / 2, tolerance), "\(context) box \(box)")
        #expect(layout.tiles.count == count, "\(context)")
        let columnWidth = (box.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        var grid: [String: NSRect] = [:]
        for (index, tile) in layout.tiles.enumerated() {
            #expect(tile.row == index / columns && tile.column == index % columns, "\(context) tile \(index) not row-major")
            #expect(i315Close(tile.frame.width, columnWidth, tolerance) && i315Close(tile.frame.height, rowHeight, tolerance),
                    "\(context) tile \(tile.row),\(tile.column) size \(tile.frame.size)")
            grid["\(tile.row),\(tile.column)"] = tile.frame
        }
        for tile in layout.tiles {
            let frame = tile.frame, cell = "\(context) tile \(tile.row),\(tile.column)"
            if tile.column == 0 { #expect(i315Close(frame.minX, 0, tolerance), "\(cell)") }
            if tile.column == columns - 1 { #expect(i315Close(frame.maxX, box.width, tolerance), "\(cell)") }
            if let next = grid["\(tile.row),\(tile.column + 1)"] {
                #expect(i315Close(next.minX - frame.maxX, gap, tolerance), "\(cell) row gap")
            }
            if let lower = grid["\(tile.row + 1),\(tile.column)"] {
                #expect(i315Close(frame.minY - lower.maxY, gap, tolerance), "\(cell) column gap")
            }
            if tile.column % 2 == 1, let neighbour = grid["\(tile.row),\(tile.column - 1)"] {
                #expect(i315Close(frame.minY, neighbour.minY - offset, tolerance), "\(cell) odd column offset")
            }
            if tile.row == 0, tile.column % 2 == 0 { #expect(i315Close(frame.maxY, box.height, tolerance), "\(cell)") }
        }
        if let first = layout.tiles.first { columnWidths.append((size.width, first.frame.width, first.frame.height)) }
    }
    let sorted = columnWidths.sorted { $0.width < $1.width }
    for (lower, upper) in zip(sorted, sorted.dropFirst()) where lower.width < upper.width {
        #expect(upper.column > lower.column, "seed 0x3150 column width not increasing \(lower.width) → \(upper.width)")
        #expect(i315Close(upper.row, lower.row, tolerance), "seed 0x3150 row height varies \(lower.width) → \(upper.width)")
    }
}

@Test @MainActor func i315RenderedWallTilesFollowLayoutTiltAndOffset() throws {
    let pinned = try PinnedDesign.page("first-launch")
    let tilt = CGFloat(-(try pinned.rotationDegrees(".wall .tiles")))
    let offset = CGFloat(try pinned.translateY(".wall .tiles>:nth-child(2n)"))
    for size in [NSSize(width: 960, height: 640), NSSize(width: 800, height: 680)] {
        let (scene, home) = try i315Scene(size)
        defer { scene.window.close() }
        let wall = try #require(wallView(home))
        let wallLayerRoot = try #require(wall.layer)
        let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
        let layout = FirstLaunchLayout.wall(in: wall.bounds.size)
        let c = CGPoint(x: wall.bounds.midX, y: wall.bounds.midY)
        let (w, h) = (layout.box.width, layout.box.height)
        #expect(i315Close(tiles.bounds.width, w, 0.5) && i315Close(tiles.bounds.height, h, 0.5), "\(size) \(tiles.bounds)")
        #expect(i315Close(tiles.position, c, 0.5), "\(size) position \(tiles.position)")
        let containers = tileContainers(home)
        #expect(containers.count == layout.tiles.count, "\(size)")
        for (container, tile) in zip(containers, layout.tiles) {
            #expect(i315Close(container.frame, tile.frame, 0.5), "\(size) tile \(tile.row),\(tile.column) \(container.frame)")
        }
        let centre = tiles.convert(CGPoint(x: tiles.bounds.midX, y: tiles.bounds.midY), to: wallLayerRoot)
        #expect(i315Close(centre, c, 0.5), "\(size) box centre \(centre)")
        let corner = tiles.convert(CGPoint(x: tiles.bounds.minX, y: tiles.bounds.maxY), to: wallLayerRoot)
        let cornerOffset = rotated(CGVector(dx: -w / 2, dy: h / 2), degrees: tilt)
        #expect(i315Close(corner, CGPoint(x: c.x + cornerOffset.dx, y: c.y + cornerOffset.dy), 0.5), "\(size) top-left \(corner)")
        let t = tiles.affineTransform()
        #expect(i315Close(atan2(t.b, t.a) * 180 / .pi, tilt, 0.01), "\(size) tilt \(atan2(t.b, t.a) * 180 / .pi)")
        let rightEdge = tiles.convert(CGPoint(x: tiles.bounds.maxX, y: tiles.bounds.midY), to: wallLayerRoot)
        let leftEdge = tiles.convert(CGPoint(x: tiles.bounds.minX, y: tiles.bounds.midY), to: wallLayerRoot)
        #expect(rightEdge.y > leftEdge.y, "\(size) right side not raised")
        guard containers.count > 1 else { continue }
        func centreInWall(_ layer: CALayer) -> CGPoint {
            tiles.convert(CGPoint(x: layer.frame.midX, y: layer.frame.midY), to: wallLayerRoot)
        }
        let first = centreInWall(containers[0]), second = centreInWall(containers[1])
        let step = rotated(CGVector(dx: layout.tiles[0].frame.width + FirstLaunchLayout.gap, dy: -offset), degrees: tilt)
        #expect(i315Close(CGPoint(x: second.x - first.x, y: second.y - first.y), CGPoint(x: step.dx, y: step.dy), 0.5),
                "\(size) odd column step \(second.x - first.x),\(second.y - first.y)")
    }
}

@Test @MainActor func i315WallRelayoutsOnResize() throws {
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    var boxes: [NSRect] = []
    for size in [NSSize(width: 960, height: 640), NSSize(width: 1440, height: 900), NSSize(width: 800, height: 680)] {
        try resize(scene, to: size)
        let wall = try #require(wallView(home))
        let wallLayerRoot = try #require(wall.layer)
        let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
        let layout = FirstLaunchLayout.wall(in: wall.bounds.size)
        boxes.append(layout.box)
        #expect(i315Close(tiles.bounds.width, layout.box.width, 0.5) && i315Close(tiles.bounds.height, layout.box.height, 0.5),
                "\(size) \(tiles.bounds)")
        let centre = tiles.convert(CGPoint(x: tiles.bounds.midX, y: tiles.bounds.midY), to: wallLayerRoot)
        #expect(i315Close(centre, CGPoint(x: wall.bounds.midX, y: wall.bounds.midY), 0.5), "\(size) centre \(centre)")
        let containers = tileContainers(home)
        #expect(containers.count == layout.tiles.count, "\(size)")
        for (container, tile) in zip(containers, layout.tiles) {
            let cell = "\(size) tile \(tile.row),\(tile.column)"
            #expect(i315Close(container.frame, tile.frame, 0.5), "\(cell) \(container.frame)")
            #expect(container.shadowPath.map { i315Close($0.boundingBox, container.bounds, 0.5) } == true, "\(cell) shadowPath")
            #expect(imageLayer(container).map { i315Close($0.frame, container.bounds, 0.5) } == true, "\(cell) image frame")
        }
    }
    #expect(boxes.count == 3 && boxes[1].width != boxes[0].width, "stale geometry would pass: \(boxes)")
}

@Test @MainActor func i315DecodedContentsSurviveResizeAndThemeChange() async throws {
    for failing in [nil, "gate"] as [String?] {
        var urls: [String: URL]?
        if let failing {
            urls = [:]
            for name in i315Samples { urls?[name] = name == failing ? i315Missing : FirstLaunchView.sampleURL(name: name) }
        }
        let view = try await i315Launch(urls)
        #expect(view.sampleLoadCompleted, "failing \(failing ?? "none")")
        let before = tileContainers(view).map { ($0.name, $0.isHidden, cgImage(imageLayer($0))) }
        #expect(before.count == 60)
        let steps: [(String, () -> Void)] = [
            ("1440×900", { view.frame = NSRect(x: 0, y: 0, width: 1440, height: 900) }),
            ("darkAqua", { view.appearance = NSAppearance(named: .darkAqua) }),
            ("800×680", { view.frame = NSRect(x: 0, y: 0, width: 800, height: 680) }),
            ("aqua", { view.appearance = NSAppearance(named: .aqua) })
        ]
        for (label, apply) in steps {
            apply()
            view.layoutSubtreeIfNeeded()
            let context = "failing \(failing ?? "none") after \(label)"
            let containers = tileContainers(view)
            #expect(containers.map(\.name) == before.map(\.0), "\(context)")
            #expect(containers.map(\.isHidden) == before.map(\.1), "\(context)")
            let hidden = containers.filter(\.isHidden)
            if let failing {
                #expect(Set(hidden.compactMap(\.name)) == [failing] && hidden.count == 10, "\(context)")
            } else {
                #expect(hidden.isEmpty, "\(context)")
            }
            for (container, record) in zip(containers, before) {
                if container.isHidden {
                    #expect(imageLayer(container)?.contents == nil, "\(context) \(record.0 ?? "?")")
                } else {
                    let current = cgImage(imageLayer(container))
                    #expect(current != nil && current === record.2, "\(context) \(record.0 ?? "?") contents replaced")
                }
            }
        }
    }
}

@Test @MainActor func i315WallOpacityFollowsThemeToken() throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    for (appearance, page) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark), (.aqua, light)] {
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        let expected = try #require(Double(page.raw(".wall .tiles", "opacity", viewport: 960)))
        let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
        #expect(abs(Double(tiles.opacity) - expected) < 0.001, "\(appearance.rawValue) tiles opacity \(tiles.opacity)")
        #expect(wall.alphaValue == 1, "\(appearance.rawValue)")
    }
}

@Test @MainActor func i315OnlyTilesLayerCarriesWallOpacity() async throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    try await waitForSamples(home)
    #expect(home.sampleLoadCompleted)
    let wall = try #require(wallView(home))
    for (appearance, page) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark)] {
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        let expected = try #require(Double(page.raw(".wall .tiles", "opacity", viewport: 960)))
        let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
        let scrim = try #require(wallLayer("first-launch.wall.scrim", in: home))
        let wallOpacity = try #require(wall.layer?.opacity)
        #expect(scrim.opacity == 1 && !scrim.isHidden, "\(appearance.rawValue) scrim")
        #expect(wallOpacity == 1 && wall.alphaValue == 1, "\(appearance.rawValue) wall")
        let containers = tileContainers(home)
        #expect(containers.count == 60)
        for container in containers {
            let image = try #require(imageLayer(container))
            let cell = "\(appearance.rawValue) \(container.name ?? "?")"
            #expect(container.opacity == 1 && !container.isHidden, "\(cell)")
            #expect(image.opacity == 1, "\(cell)")
            let product = Double(image.opacity * container.opacity * tiles.opacity * wallOpacity) * Double(wall.alphaValue)
            #expect(abs(product - expected) < 0.001, "\(cell) opacity product \(product)")
        }
    }
}

@Test @MainActor func i315WallTileRadiusRingAndShadowFollowThemeShadowSoft() throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    for (appearance, page) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark)] {
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        let layers = try page.boxShadowLayers(":root", "--shadow-soft", viewport: 960)
        try #require(layers.count == 2)
        let radius = CGFloat(try page.length(":root", "--radius-control", viewport: 960))
        #expect(try page.raw(".wall img", "object-fit", viewport: 960) == "cover")
        let containers = tileContainers(home)
        #expect(containers.count == 60)
        for container in containers {
            let image = try #require(imageLayer(container))
            let cell = "\(appearance.rawValue) \(container.name ?? "?")"
            #expect(image.cornerRadius == radius && image.masksToBounds, "\(cell) radius \(image.cornerRadius)")
            #expect(image.contentsGravity == .resizeAspectFill, "\(cell)")
            let ringLayer = try #require(tileRing(container), "\(cell) ring layer")
            #expect(abs(Double(ringLayer.borderWidth) - layers[0].spread) < 0.001, "\(cell) ring width \(ringLayer.borderWidth)")
            let ring = try srgb(ringLayer.borderColor)
            #expect(i315Close(ring, layers[0].color), "\(cell) ring \(ring) vs \(layers[0].color)")
            #expect(Double(container.shadowOffset.width) == layers[1].x && Double(container.shadowOffset.height) == -layers[1].y,
                    "\(cell) shadow offset \(container.shadowOffset)")
            #expect(abs(Double(container.shadowRadius) - layers[1].blur / 2) < 0.001, "\(cell) shadow radius \(container.shadowRadius)")
            let shadow = try srgb(container.shadowColor)
            #expect(i315Close(PinnedDesign.Color(red: shadow.red, green: shadow.green, blue: shadow.blue, alpha: 0),
                              PinnedDesign.Color(red: layers[1].color.red, green: layers[1].color.green,
                                                 blue: layers[1].color.blue, alpha: 0)),
                    "\(cell) shadow rgb \(shadow) vs \(layers[1].color)")
            #expect(abs(shadow.alpha * Double(container.shadowOpacity) - layers[1].color.alpha) < 0.01,
                    "\(cell) shadow alpha \(shadow.alpha) × \(container.shadowOpacity)")
            #expect(container.shadowPath.map { i315Close($0.boundingBox, container.bounds, 0.5) } == true, "\(cell) shadowPath")
        }
    }
}

/// Audit M2: `--shadow-soft`'s first layer is an outer zero-blur spread, so the ring lies outside the image
/// (from its edge out by the spread, at radius + spread); a CALayer border on the image would cover its edge.
@Test @MainActor func i315WallTileRingSitsOutsideImageBounds() throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    for (size, appearance, page) in [(NSSize(width: 960, height: 640), NSAppearance.Name.aqua, light),
                                     (NSSize(width: 1440, height: 900), .darkAqua, dark)] {
        try resize(scene, to: size)
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        let spread = CGFloat(try page.boxShadowLayers(":root", "--shadow-soft", viewport: 960)[0].spread)
        let radius = CGFloat(try page.length(":root", "--radius-control", viewport: 960))
        #expect(spread == 0.5)
        for container in tileContainers(home) {
            let cell = "\(appearance.rawValue) \(size) \(container.name ?? "?")"
            guard let image = imageLayer(container) else { Issue.record("\(cell) no image"); continue }
            #expect(image.borderWidth == 0, "\(cell) image border \(image.borderWidth) paints inside the image")
            #expect(i315Close(image.frame, container.bounds, 0.001) && image.cornerRadius == radius, "\(cell) image crop")
            let ring = tileRing(container)
            #expect(ring != nil, "\(cell) no ring layer")
            guard let ring else { continue }
            #expect(!ring.masksToBounds && ring.contents == nil && ring.backgroundColor == nil, "\(cell) ring fill")
            #expect(i315Close(ring.frame, image.frame.insetBy(dx: -spread, dy: -spread), 0.001),
                    "\(cell) ring frame \(ring.frame) vs image \(image.frame)")
            #expect(ring.borderWidth == spread, "\(cell) ring width \(ring.borderWidth)")
            #expect(ring.cornerRadius == radius + spread, "\(cell) ring radius \(ring.cornerRadius)")
        }
        #expect(!anyTileContainerMasks(home), "a tile container clips its ring")
    }
}

// MARK: - WI-3 drop outline inset and centre placement (pinned page 21)

@Test @MainActor func i315DropOutlineInsetsContentByPinnedInset() throws {
    let pinned = try PinnedDesign.page("first-launch")
    for size in [NSSize(width: 960, height: 640), NSSize(width: 800, height: 680), NSSize(width: 1440, height: 900)] {
        let (scene, home) = try i315Scene(size)
        defer { scene.window.close() }
        let titleBar = CGFloat(try pinned.length(":root", "--title-bar-height", viewport: size.width))
        let inset = CGFloat(try pinned.length(".drop-outline", "inset", viewport: size.width))
        let radius = CGFloat(try pinned.length(".drop-outline", "border-radius", viewport: size.width))
        let border = try pinned.border(".drop-outline")
        let drop = try #require(wallTestView("first-launch.drop", in: home))
        let frame = drop.convert(drop.bounds, to: home)
        let expected = NSRect(x: 0, y: 0, width: size.width, height: size.height - titleBar).insetBy(dx: inset, dy: inset)
        #expect(i315Close(frame, expected, 0.001), "\(size) drop \(frame) vs \(expected)")
        #expect(drop.layer?.cornerRadius == radius, "\(size) radius \(String(describing: drop.layer?.cornerRadius))")
        let outline = try #require(drop.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        #expect(Double(outline.lineWidth) == border.width, "\(size) line \(outline.lineWidth)")
        #expect(border.style == "dashed" && outline.lineDashPattern?.isEmpty == false, "\(size) dash")
        let half = outline.lineWidth / 2
        let path = try #require(outline.path)
        #expect(i315Close(path.boundingBoxOfPath, drop.bounds.insetBy(dx: half, dy: half), 0.001),
                "\(size) outline path \(path.boundingBoxOfPath)")
        let corner = path.boundingBoxOfPath
        #expect(!path.contains(CGPoint(x: corner.minX + 0.5, y: corner.minY + 0.5))
                && path.contains(CGPoint(x: corner.minX + radius, y: corner.minY + radius)),
                "\(size) outline path corner radius not \(radius)")
    }
}

@Test @MainActor func i315CentreGroupCentresOnContentMidpoint() throws {
    let pinned = try PinnedDesign.page("first-launch")
    let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("B4PinnedDesign")
    let b4 = try PinnedDesign.page("b4-first-launch", source: fixtureRoot.appendingPathComponent("a/b/c/d/source.swift").path)
    let gap = CGFloat(try b4.length(".centre", "gap", viewport: 960))
    let seed: UInt64 = 0x3153
    let sizes = generatedSizes(seed: seed, count: 40, width: 800...2400, height: 680...1600) + [NSSize(width: 960, height: 640)]
    let scene = StatesScene(width: 960)
    defer { scene.window.close() }
    scene.state.display(.empty)
    for size in sizes {
        try resize(scene, to: size)
        let home = try launch(in: scene)
        let context = "seed 0x3153 size \(size)"
        let titleBar = CGFloat(try pinned.length(":root", "--title-bar-height", viewport: size.width))
        let views = centreViews(home)
        try #require(views.count == 4, "\(context)")
        let group = views.map { $0.convert($0.bounds, to: home) }.reduce(views[0].convert(views[0].bounds, to: home)) { $0.union($1) }
        let drop = try #require(wallTestView("first-launch.drop", in: home))
        let dropFrame = drop.convert(drop.bounds, to: home)
        #expect(i315Close(group.midY, dropFrame.midY, 0.5), "\(context) group \(group) drop \(dropFrame)")
        #expect(i315Close(group.midY, (size.height - titleBar) / 2, 0.5), "\(context) group midY \(group.midY)")
        #expect(i315Close(group.midX, size.width / 2, 0.5), "\(context) group midX \(group.midX)")
        let heading = try #require(wallTestView("first-launch.heading", in: home))
        let button = try #require(wallTestView("state.open", in: home))
        #expect(wallTestView("first-launch.chip.images", in: home) == nil, "\(context) chips row")
        #expect(i315Close(heading.frame.minY - button.frame.maxY, gap, 1), "\(context) heading→button")
        #expect(heading.frame.height == 24 && button.frame.height == 30,
                "\(context) heights \(heading.frame.height) \(button.frame.height)")
    }
}

/// #441: with the chips row gone, the hint and the button keep re-pinned page 21's positions, measured from the
/// content top (the native title bar strip is the contract's exception), in both appearances, idle and dragging.
@Test @MainActor func i441CentreKeepsPinnedPositionsAt1280x800() throws {
    let pinned = try PinnedDesign.page("first-launch")
    let viewport: Double = 1280
    let titleBar = try pinned.length(":root", "--title-bar-height", viewport: viewport)
    let inset = try pinned.length(".home-centre", "inset", viewport: viewport)
    let gap = try pinned.length(".home-centre", "gap", viewport: viewport)
    let hintHeight = try pinned.length(".home-centre h2", "line-height", viewport: viewport)
    let buttonHeight = try pinned.length(".home-sub .mock-primary", "height", viewport: viewport)
    let box = 800 - titleBar - 2 * inset
    let hintTop = inset + (box - (hintHeight + gap + buttonHeight)) / 2
    let expected = [hintTop, hintTop + hintHeight, hintTop + hintHeight + gap, hintTop + hintHeight + gap + buttonHeight]
    // Chromium measured the re-pinned page at 1280×800: hint 345–369, button 387–417 from the content top.
    #expect(expected == [345, 369, 387, 417], "derived \(expected)")
    let (scene, home) = try i315Scene(NSSize(width: 1280, height: 800))
    defer { scene.window.close() }
    try #require(home.bounds.height == 800)
    let heading = try #require(wallTestView("first-launch.heading", in: home))
    let button = try #require(wallTestView("state.open", in: home))
    var frames: [[CGFloat]] = []
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for drag in [false, true] {
            let context = "\(appearance.rawValue) drag \(drag)"
            home.appearance = NSAppearance(named: appearance)
            scene.state.setFirstLaunchDragActive(drag)
            home.layoutSubtreeIfNeeded()
            let top = home.bounds.height - CGFloat(titleBar)
            let h = heading.convert(heading.bounds, to: home), b = button.convert(button.bounds, to: home)
            let measured = [top - h.maxY, top - h.minY, top - b.maxY, top - b.minY]
            for (got, want) in zip(measured, expected) {
                #expect(i315Close(got, CGFloat(want), 1), "\(context) measured \(measured) want \(expected)")
            }
            #expect(Double(b.height) == buttonHeight, "\(context) button height \(b.height)")
            frames.append(measured)
        }
    }
    #expect(Set(frames.map { $0.map { Int(($0 * 100).rounded()) } }).count == 1, "centre moves between presentations \(frames)")
}

// MARK: - WI-4 drag lifecycle on the wall and drop prompt (pinned page 21)

private func i315B4Page(dark: Bool) throws -> PinnedDesign {
    let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("B4PinnedDesign")
    return try PinnedDesign.page("b4-first-launch", source: fixtureRoot.appendingPathComponent("a/b/c/d/source.swift").path,
                                 appearance: dark ? "dark" : nil)
}

private func i315DragWallAlpha() throws -> CGFloat {
    let value = try PinnedDesign.page("first-launch").exactDeclaration(".is-drag-over .wall", "opacity")
    return CGFloat(try #require(Double(value), "'.is-drag-over .wall' opacity '\(value)'"))
}

@Test @MainActor func i315DragSequencesRoundTripToIdleAndActive() async throws {
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    try await waitForSamples(home)
    #expect(home.sampleLoadCompleted)
    let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    var reference: [NSAppearance.Name: [Bool: WallPresentation]] = [:]
    for appearance in appearances {
        for drag in [false, true] {
            home.appearance = NSAppearance(named: appearance)
            scene.state.setFirstLaunchDragActive(false)
            home.layoutSubtreeIfNeeded()
            scene.state.setFirstLaunchDragActive(drag)
            home.layoutSubtreeIfNeeded()
            reference[appearance, default: [:]][drag] = try wallPresentation(home)
        }
    }
    let aquaIdle = try #require(reference[.aqua]?[false])
    for appearance in appearances {
        let idle = try #require(reference[appearance]?[false]), active = try #require(reference[appearance]?[true])
        #expect(idle.wallAlpha != active.wallAlpha, "\(appearance.rawValue) wall alpha does not change on drag")
        #expect(idle.heading != active.heading, "\(appearance.rawValue) heading does not change on drag")
        #expect(idle.outlineHidden != active.outlineHidden, "\(appearance.rawValue) outline does not change on drag")
    }
    for drag in [false, true] {
        let light = try #require(reference[.aqua]?[drag]), dark = try #require(reference[.darkAqua]?[drag])
        #expect(light.tilesOpacity != dark.tilesOpacity, "drag \(drag) tiles opacity ignores theme")
        #expect(light.headingColor != dark.headingColor, "drag \(drag) heading colour ignores theme")
    }

    let seed: UInt64 = 0x3154
    var generator = SplitMix64(seed: seed)
    for index in 0..<128 {
        home.appearance = NSAppearance(named: .aqua)
        scene.state.setFirstLaunchDragActive(false)
        home.layoutSubtreeIfNeeded()
        #expect(try wallPresentation(home) == aquaIdle, "seed 0x3154 sequence \(index) reset")
        let events = (0..<Int.random(in: 1...10, using: &generator)).map { _ in Int.random(in: 0..<4, using: &generator) }
        var lastAppearance = NSAppearance.Name.aqua, lastDrag = false
        for (step, event) in events.enumerated() {
            switch event {
            case 0: scene.state.setFirstLaunchDragActive(true); lastDrag = true
            case 1: scene.state.setFirstLaunchDragActive(false); lastDrag = false
            case 2: home.appearance = NSAppearance(named: .aqua); lastAppearance = .aqua
            default: home.appearance = NSAppearance(named: .darkAqua); lastAppearance = .darkAqua
            }
            home.layoutSubtreeIfNeeded()
            let expected = try #require(reference[lastAppearance]?[lastDrag])
            #expect(try wallPresentation(home) == expected,
                    "seed 0x3154 sequence \(index) events \(events) step \(step): expected \(lastAppearance.rawValue) drag \(lastDrag)")
        }
    }
}

@Test @MainActor func i315DecodeFinishingDuringDragKeepsActivePresentation() async throws {
    let pinned = try PinnedDesign.page("first-launch")
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    #expect(home.sampleLoadCompleted == false, "decode finished before the drag began")
    scene.state.setFirstLaunchDragActive(true)
    try await waitForSamples(home)
    #expect(home.sampleLoadCompleted)
    let wall = try #require(wallView(home))
    let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
    let heading = try #require(wallTestView("first-launch.heading", in: home) as? NSTextField)
    let outline = try #require(dropOutline(home))
    #expect(abs(wall.alphaValue - (try i315DragWallAlpha())) < 0.001, "wall alpha after decode \(wall.alphaValue)")
    let tilesOpacity = try #require(Double(pinned.raw(".wall .tiles", "opacity", viewport: 960)))
    #expect(abs(Double(tiles.opacity) - tilesOpacity) < 0.001, "tiles opacity after decode \(tiles.opacity)")
    let containers = tileContainers(home)
    #expect(containers.count == 60)
    #expect(containers.allSatisfy { $0.opacity == 1 && !$0.isHidden }, "a decoded tile is faded or hidden")
    #expect(heading.stringValue == "Release to open")
    #expect(!outline.isHidden)

    scene.state.setFirstLaunchDragActive(false)
    home.layoutSubtreeIfNeeded()
    let (fresh, freshHome) = try i315Scene()
    defer { fresh.window.close() }
    try await waitForSamples(freshHome)
    #expect(freshHome.sampleLoadCompleted)
    #expect(try wallPresentation(home) == wallPresentation(freshHome), "idle after a drag that spanned decode")
}

@Test @MainActor func i315DragActiveValuesComeFromPinnedPage() throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    let dragAlpha = try i315DragWallAlpha()
    #expect(abs(dragAlpha - 0.4) < 0.001)
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    let tiles = try #require(wallLayer("first-launch.wall.tiles", in: home))
    let heading = try #require(wallTestView("first-launch.heading", in: home) as? NSTextField)
    let drop = try #require(wallTestView("first-launch.drop", in: home))
    let outline = try #require(dropOutline(home))
    for (appearance, page) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark)] {
        let context = appearance.rawValue
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        let tilesOpacity = tiles.opacity
        scene.state.setFirstLaunchDragActive(true)
        home.layoutSubtreeIfNeeded()
        #expect(abs(wall.alphaValue - dragAlpha) < 0.001, "\(context) wall alpha \(wall.alphaValue)")
        #expect(tiles.opacity == tilesOpacity, "\(context) tiles opacity changed on drag")
        #expect(heading.stringValue == "Release to open", "\(context)")
        let accentText = try page.color(":root", "--color-accent-text", viewport: 960)
        let headingActive = try headingColour(home)
        #expect(i315Close(headingActive, accentText), "\(context) heading \(headingActive) vs accent-text \(accentText)")
        #expect(!outline.isHidden && outline.lineWidth == 1.5, "\(context) outline")
        let stroke = try srgb(outline.strokeColor), accent = try page.color(":root", "--color-accent", viewport: 960)
        #expect(i315Close(stroke, accent), "\(context) outline \(stroke) vs accent \(accent)")
        let fill = try srgb(drop.layer?.backgroundColor), soft = try page.color(":root", "--color-accent-soft", viewport: 960)
        #expect(i315Close(fill, soft), "\(context) drop fill \(fill) vs accent-soft \(soft)")

        scene.state.setFirstLaunchDragActive(false)
        home.layoutSubtreeIfNeeded()
        #expect(heading.stringValue == "Drop a photo folder here", "\(context)")
        let text = try page.color(":root", "--color-text", viewport: 960)
        let headingIdle = try headingColour(home)
        #expect(i315Close(headingIdle, text), "\(context) idle heading \(headingIdle) vs text \(text)")
        #expect(outline.isHidden, "\(context) outline still shown")
        #expect(try srgb(drop.layer?.backgroundColor).alpha == 0, "\(context) drop fill not cleared")
        #expect(wall.alphaValue == 1, "\(context) wall alpha \(wall.alphaValue) after drag")
    }
}

@Test @MainActor func i315WallFadeUsesFastMotionDurationUnlessReduceMotion() throws {
    let pinned = try PinnedDesign.page("first-launch")
    let fast = try PinnedDesign.seconds(pinned.rootToken("--motion-duration-fast"))
    #expect(fast > 0)
    #expect(try PinnedDesign.seconds(pinned.rootToken("--motion-duration-fast", media: "prefers-reduced-motion:reduce")) == 0)
    let dragAlpha = try i315DragWallAlpha()
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    for reduceMotion in [false, true] {
        home.pinAccessibility(reduceMotion: reduceMotion)
        for drag in [true, false] {
            let context = "reduceMotion \(reduceMotion) drag \(drag)"
            scene.state.setFirstLaunchDragActive(drag)
            let target: CGFloat = drag ? dragAlpha : 1
            #expect(abs(wall.alphaValue - target) < 0.001, "\(context) wall alpha \(wall.alphaValue)")
            let animations = wallOpacityAnimations(home)
            if reduceMotion {
                #expect(animations.isEmpty, "\(context) wall fades under Reduce Motion")
            } else {
                #expect(animations.count == 1, "\(context) opacity animations \(animations.count)")
                #expect(animations.allSatisfy { abs($0.duration - fast) < 0.0001 },
                        "\(context) durations \(animations.map(\.duration)) vs \(fast)")
            }
            wall.layer?.removeAllAnimations()
            scene.state.setFirstLaunchDragActive(drag)
            #expect(wallOpacityAnimations(home).isEmpty, "\(context) a repeated call animated again")
            #expect(abs(wall.alphaValue - target) < 0.001, "\(context) repeated call moved alpha \(wall.alphaValue)")
        }
    }
}

@Test @MainActor func i315ReduceTransparencyDragHidesWallAndUsesOpaqueDropFill() throws {
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    home.pinAccessibility(reduceTransparency: true)
    let wall = try #require(wallView(home))
    let drop = try #require(wallTestView("first-launch.drop", in: home))
    for (appearance, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
        let context = appearance.rawValue
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        scene.state.setFirstLaunchDragActive(true)
        home.layoutSubtreeIfNeeded()
        #expect(wall.alphaValue == 0, "\(context) wall alpha \(wall.alphaValue) under Reduce Transparency")
        let fill = try srgb(drop.layer?.backgroundColor)
        let expected = try i315B4Page(dark: dark).color(".rt.over .drop", "background", viewport: 960)
        #expect(i315Close(fill, expected) && fill.alpha == 1, "\(context) drop fill \(fill) vs \(expected)")
        scene.state.setFirstLaunchDragActive(false)
        home.layoutSubtreeIfNeeded()
        #expect(wall.alphaValue == 1, "\(context) wall alpha \(wall.alphaValue) after drag")
        #expect(try srgb(drop.layer?.backgroundColor).alpha == 0, "\(context) drop fill not cleared")
    }
}

@Test @MainActor func i315LiveAccessibilityChangeRestylesWallDuringDrag() throws {
    let dragAlpha = try i315DragWallAlpha()
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    let drop = try #require(wallTestView("first-launch.drop", in: home))
    let heading = try #require(wallTestView("first-launch.heading", in: home) as? NSTextField)
    scene.state.setFirstLaunchDragActive(true)
    home.layoutSubtreeIfNeeded()
    #expect(abs(wall.alphaValue - dragAlpha) < 0.001, "wall alpha \(wall.alphaValue) before the change")
    #expect(!wallOpacityAnimations(home).isEmpty, "no fade running before the change")
    home.reduceTransparencyOverride = true
    home.reduceMotionOverride = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    home.layoutSubtreeIfNeeded()
    #expect(wall.alphaValue == 0, "wall alpha \(wall.alphaValue) after Reduce Transparency turned on")
    #expect(try srgb(drop.layer?.backgroundColor).alpha == 1, "drop fill not opaque")
    #expect(wallOpacityAnimations(home).isEmpty, "fade still running under Reduce Motion")
    home.reduceTransparencyOverride = false
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    home.layoutSubtreeIfNeeded()
    #expect(abs(wall.alphaValue - dragAlpha) < 0.001, "wall alpha \(wall.alphaValue) after Reduce Transparency turned off")
    #expect(heading.stringValue == "Release to open")
}

@Test @MainActor func i315DropViewLifecycleDrivesWallThroughHost() async throws {
    let dragAlpha = try i315DragWallAlpha()
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    try await waitForSamples(home)
    let idle = try wallPresentation(home)
    scene.state.setFirstLaunchDragActive(true)
    home.layoutSubtreeIfNeeded()
    let active = try wallPresentation(home)
    scene.state.setFirstLaunchDragActive(false)
    home.layoutSubtreeIfNeeded()
    #expect(abs(active.wallAlpha - dragAlpha) < 0.001 && active.heading == "Release to open" && !active.outlineHidden,
            "active reference \(active.wallAlpha) \(active.heading)")
    #expect(idle.wallAlpha == 1 && idle.outlineHidden && idle.heading == "Drop a photo folder here")

    let files = NSPasteboard.withUniqueName(), strings = NSPasteboard.withUniqueName()
    defer { files.releaseGlobally(); strings.releaseGlobally() }
    #expect(files.writeObjects([URL(fileURLWithPath: "/photos/A.jpg") as NSURL]))
    #expect(strings.writeObjects(["not a file" as NSString]))
    var dropped = 0
    let dropView = ViewerDropView(frame: scene.state.bounds, acceptsDrop: { true }, onDrop: { _ in dropped += 1 })
    dropView.onDragActive = { scene.state.setFirstLaunchDragActive($0) }
    func presentation() throws -> WallPresentation { home.layoutSubtreeIfNeeded(); return try wallPresentation(home) }

    let accepted = WallDragInfo(files)
    #expect(dropView.draggingEntered(accepted) == .copy)
    #expect(try presentation() == active, "accepted enter")
    dropView.draggingExited(accepted)
    #expect(try presentation() == idle, "exited")
    #expect(dropView.draggingEntered(accepted) == .copy)
    #expect(try presentation() == active, "accepted enter before drop")
    #expect(dropView.performDragOperation(accepted))
    #expect(try presentation() == idle, "dropped")
    #expect(dropped == 1)
    #expect(dropView.draggingEntered(accepted) == .copy)
    dropView.draggingEnded(accepted)
    #expect(try presentation() == idle, "ended")

    let rejected = WallDragInfo(strings)
    #expect(dropView.draggingEntered(rejected) == [])
    #expect(try presentation() == idle, "rejected enter")
    #expect(!dropView.performDragOperation(rejected))
    #expect(try presentation() == idle, "rejected drop")
    #expect(dropped == 1)
}

// MARK: - WI-5 the wall is invisible to accessibility and never intercepts drags or clicks

private let i315AXChildren = ["first-launch.heading", "state.open", "first-launch.shortcut"]

@MainActor private func i315Descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + i315Descendants($0) }
}

/// Every identifier reachable by walking the accessibility tree (not the view tree) from `element`.
@MainActor private func i315AXReachable(_ element: Any, depth: Int = 0) -> [String] {
    guard depth < 16, let node = element as? NSAccessibilityProtocol else { return [] }
    return [node.accessibilityIdentifier() ?? ""] + (node.accessibilityChildren() ?? []).flatMap { i315AXReachable($0, depth: depth + 1) }
}

@Test @MainActor func i315WallIsInvisibleToAccessibility() throws {
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    func check(_ context: String) {
        #expect(!wall.isAccessibilityElement(), "\(context) wall is an AX element")
        #expect(wall.isAccessibilityHidden(), "\(context) wall not AX hidden")
        for view in i315Descendants(wall) {
            #expect(!view.isAccessibilityElement(), "\(context) wall subview \(view.accessibilityIdentifier()) is an AX element")
        }
        let children = (scene.state.accessibilityChildren() ?? []).map { ($0 as? NSView)?.accessibilityIdentifier() ?? "\($0)" }
        #expect(children == i315AXChildren, "\(context) AX children \(children)")
        let reachable = i315AXReachable(home)
        #expect(!reachable.contains { $0.hasPrefix("first-launch.wall") }, "\(context) AX tree reaches \(reachable)")
    }
    check("idle")
    scene.state.setFirstLaunchDragActive(true)
    home.layoutSubtreeIfNeeded()
    check("drag active")
    scene.state.setFirstLaunchDragActive(false)
    home.appearance = NSAppearance(named: .darkAqua)
    home.layoutSubtreeIfNeeded()
    check("dark after drag")
}

@Test @MainActor func i315WallNeverInterceptsDragsOrClicks() throws {
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    let host = try #require(home.superview)
    let frame = wall.frame
    var generator = SplitMix64(seed: 0x3155)
    let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                   CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
                   CGPoint(x: frame.midX, y: frame.midY)]
    let points = corners + (0..<500).map { _ in
        CGPoint(x: CGFloat.random(in: frame.minX...frame.maxX, using: &generator),
                y: CGFloat.random(in: frame.minY...frame.maxY, using: &generator))
    }
    let centre = centreViews(home).map(\.frame)
    try #require(centre.count == 4)
    for point in points {
        let context = "seed 0x3155 point \(point)"
        #expect(wall.hitTest(point) == nil, "\(context) wall hit")
        guard !centre.contains(where: { $0.contains(point) }) else { continue }
        let hit = home.hitTest(home.convert(point, to: host))
        #expect(hit.map { $0 === wall || $0.isDescendant(of: wall) } != true, "\(context) home hit \(String(describing: hit))")
    }
    let button = home.openButton
    #expect(home.hitTest(home.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: host)) === button)
    for view in [wall] + i315Descendants(wall) {
        #expect(view.registeredDraggedTypes.isEmpty, "\(view.accessibilityIdentifier()) registers \(view.registeredDraggedTypes)")
    }
    let dropView = ViewerDropView(frame: scene.state.bounds, acceptsDrop: { true }, onDrop: { _ in })
    #expect(dropView.registeredDraggedTypes.contains(.fileURL))
}

// MARK: - WI-6 the centre stays readable with the scrim behind it (pinned page 21)

@Test @MainActor func i315CentreReadableAtSupportedSizes() throws {
    let sizes = [NSSize(width: 800, height: 680)]
        + generatedSizes(seed: 0x3156, count: 30, width: 800...2400, height: 680...1600)
    let scene = StatesScene(width: 960)
    defer { scene.window.close() }
    scene.state.display(.empty)
    for size in sizes {
        try resize(scene, to: size)
        let home = try launch(in: scene)
        for dragActive in [false, true] {
            scene.state.setFirstLaunchDragActive(dragActive)
            for language in ["en", "zh"] {
                let context = "seed 0x3156 size \(size) drag \(dragActive) \(language)"
                if language == "zh" {
                    let heading = try #require(wallTestView("first-launch.heading", in: home) as? NSTextField)
                    heading.stringValue = dragActive ? "松开即可打开" : "把照片文件夹拖到这里"
                    let shortcut = try #require(wallTestView("first-launch.shortcut", in: home) as? NSTextField)
                    shortcut.stringValue = "或按 ⌘O"
                }
                home.needsLayout = true
                home.layoutSubtreeIfNeeded()
                let drop = try #require(wallTestView("first-launch.drop", in: home)).frame
                let views = centreViews(home)
                try #require(views.count == 4, "\(context)")
                for view in views {
                    let id = view.accessibilityIdentifier()
                    #expect(!view.isHidden && view.alphaValue > 0, "\(context) \(id) hidden")
                    #expect(view.frame.width > 0 && view.frame.height > 0, "\(context) \(id) frame \(view.frame)")
                    #expect(drop.contains(view.frame), "\(context) \(id) \(view.frame) outside drop \(drop)")
                }
                for (i, a) in views.enumerated() {
                    for b in views[(i + 1)...] {
                        let overlap = a.frame.intersection(b.frame)
                        #expect(overlap.isEmpty || overlap.width * overlap.height == 0,
                                "\(context) \(a.accessibilityIdentifier()) overlaps \(b.accessibilityIdentifier()) by \(overlap)")
                    }
                }
            }
        }
    }
}

@Test @MainActor func i315ScrimSitsAboveTilesBelowCentre() throws {
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    let sublayers = try #require(wall.layer?.sublayers)
    let tiles = try #require(sublayers.firstIndex { $0.name == "first-launch.wall.tiles" })
    let scrimIndex = try #require(sublayers.firstIndex { $0.name == "first-launch.wall.scrim" })
    #expect(tiles < scrimIndex, "tiles \(tiles) scrim \(scrimIndex)")
    let scrim = try #require(sublayers[scrimIndex] as? CAGradientLayer)
    #expect(scrim.type == .radial)
    #expect(scrim.frame == wall.bounds, "scrim \(scrim.frame) wall \(wall.bounds)")
    let wallIndex = try #require(home.subviews.firstIndex { $0 === wall })
    let above = [try #require(wallTestView("first-launch.drop", in: home))] + centreViews(home)
    try #require(above.count == 5)
    for view in above {
        let index = try #require(home.subviews.firstIndex { $0 === view }, "\(view.accessibilityIdentifier()) not a Home subview")
        #expect(wallIndex < index, "\(view.accessibilityIdentifier()) index \(index) below wall \(wallIndex)")
    }
}

@Test @MainActor func i315ScrimColoursFollowPinnedRadialGradient() throws {
    let light = try PinnedDesign.page("first-launch")
    let dark = try PinnedDesign.page("first-launch", appearance: "dark")
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    var reads: [[PinnedDesign.Color]] = []
    for (appearance, page) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark), (.aqua, light)] {
        home.appearance = NSAppearance(named: appearance)
        home.layoutSubtreeIfNeeded()
        let g = try page.radialGradient(".wall::after", viewport: 960)
        let scrim = try #require(wallLayer("first-launch.wall.scrim", in: home) as? CAGradientLayer)
        let colours = try ((scrim.colors as? [CGColor]) ?? []).map { try srgb($0) }
        reads.append(colours)
        #expect(colours.count == g.stops.count, "\(appearance.rawValue) \(colours.count) colours")
        for (index, (colour, stop)) in zip(colours, g.stops).enumerated() {
            #expect(i315Close(colour, stop.color), "\(appearance.rawValue) stop \(index) \(colour) vs \(stop.color)")
        }
        #expect((scrim.locations ?? []).map(\.doubleValue) == g.stops.map(\.location),
                "\(appearance.rawValue) locations \(String(describing: scrim.locations))")
        #expect(i315Close(scrim.startPoint, CGPoint(x: g.centreX / 100, y: g.centreY / 100), 0.0001),
                "\(appearance.rawValue) start \(scrim.startPoint)")
        #expect(i315Close(scrim.endPoint, CGPoint(x: 0.5 + g.radiusX / 100, y: 0.5 + g.radiusY / 100), 0.0001),
                "\(appearance.rawValue) end \(scrim.endPoint)")
    }
    #expect(reads.count == 3 && reads[0] == reads[2] && reads[0] != reads[1], "light → dark → light \(reads)")
}

// MARK: - Review M1: the fade runs from the alpha on screen to the drag target

@Test @MainActor func i315WallFadeRunsFromPreviousAlphaToTarget() throws {
    let dragAlpha = try i315DragWallAlpha()
    let (scene, home) = try i315Scene()
    defer { scene.window.close() }
    let wall = try #require(wallView(home))
    home.pinAccessibility(reduceMotion: false)
    var previous = wall.alphaValue
    for drag in [true, false, true, false] {
        wall.layer?.removeAllAnimations()
        scene.state.setFirstLaunchDragActive(drag)
        let target: CGFloat = drag ? dragAlpha : 1
        let fade = try #require(wallOpacityAnimations(home).first, "drag \(drag) did not fade")
        let from = try #require(fade.fromValue as? Float), to = try #require(fade.toValue as? Float)
        #expect(abs(CGFloat(from) - previous) < 0.001, "drag \(drag) fade starts at \(from), not \(previous)")
        #expect(abs(CGFloat(to) - target) < 0.001, "drag \(drag) fade ends at \(to), not \(target)")
        #expect(from != to, "drag \(drag) fade does not move")
        previous = target
    }
}

/// #398: a sample wait in a cancelled test either finds the samples loaded or throws once, naming the condition; it
/// never returns silently with the samples still loading. (The samples load in milliseconds, so this cannot hold the
/// load open; `i398SweptWaitHelpersUseTheSharedWait` pins the wait itself to the shared cancellation-driven one.)
@Test(.timeLimit(.minutes(2))) @MainActor func i398CancelledSampleWaitThrowsNamingTheCondition() async throws {
    _ = NSApplication.shared
    let view = FirstLaunchView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
                               openButton: ViewerStateButton(frame: .zero), sampleURLs: nil)
    let outcome = await Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            try await waitForSamples(view)
            return view.sampleLoadCompleted ? "completed" : "returned with the samples still loading"
        } catch { return String(describing: error) }
    }.value
    #expect(outcome == "completed" || outcome.contains("sampleLoadCompleted"), "\(outcome)")
    try await waitUntil("samples loaded") { view.sampleLoadCompleted }
}
