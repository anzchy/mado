import AppKit
import ImageIO
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor final class Issue349Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor func issue349Descendants(_ root: NSView?) -> [NSView] {
    guard let root else { return [] }
    return [root] + root.subviews.flatMap(issue349Descendants)
}

/// Actual controller/menu surfaces, kept ordered out as in #348's menu integration tests.
@MainActor final class Issue349AppScene {
    let controller: CanvasWindowController
    let window: NSWindow
    let shell: GridShellView
    let grid: GridBrowserView
    let entries: [FolderEntry]

    init(store: any DisplayPreferencesStore, count: Int = 100,
         folder: URL = URL(fileURLWithPath: "/tmp/issue349")) throws {
        _ = NSApplication.shared
        let unavailable = Task<AccessServices, Error> { throw CancellationError() }
        controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
            accessServices: unavailable, motionPolicy: MotionPolicy(source: Issue349Motion()))
        window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        shell = try #require(issue349Descendants(window.contentView).compactMap { $0 as? GridShellView }.first)
        grid = try #require(issue349Descendants(window.contentView).compactMap { $0 as? GridBrowserView }.first)
        // This fixture tests presentation/routing, not grants. A separate real ImageIO case covers decoding.
        grid.thumbnailLoader = nil
        let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
        entries = (0..<count).map { FolderEntry(url: root.url.appendingPathComponent("IMG_\($0).jpg"), root: root) }
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: root.url, generation: 1),
            entries: entries, isComplete: true), selectedItemID: entries.first?.itemID)
        controller.session.beginBrowsing(items: entries.map(\.itemID), sourceVersion: .init(1), scrollAnchor: nil)
        if let first = entries.first { controller.session.select(first.itemID) }
        controller.showGrid()
        window.orderOut(nil)
        let scroll = try #require(grid.collectionView.enclosingScrollView)
        scroll.scrollerStyle = .overlay
        scroll.tile()
        settle()
        #expect(window.makeFirstResponder(grid.collectionView))
    }

    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        for item in grid.collectionView.visibleItems() { item.view.layoutSubtreeIfNeeded() }
    }

    func tile(_ index: Int = 0) throws -> NSView {
        let cell = try #require(grid.collectionView.item(at: IndexPath(item: index, section: 0)))
        cell.view.layoutSubtreeIfNeeded()
        return try #require(cell.view.subviews.first { !($0 is NSTextField) })
    }

    func event(_ key: String, command: Bool = true) throws -> NSEvent {
        let code: UInt16 = key == "0" ? 29 : key == "9" ? 25 : key == "1" ? 18 : key == "-" ? 27 : 24
        var flags: NSEvent.ModifierFlags = command ? .command : []
        if key == "+" { flags.insert(.shift) }
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    func key(_ key: String) throws {
        #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: event(key)), "⌘\(key)")
        settle()
    }

    func close() {
        grid.stopThumbnails()
        window.close()
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue349RealWindowInstallsLargerImageIOThumbnailsAfterKeys() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("IMG_0.jpg")
    let context = try #require(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8,
        bytesPerRow: 8192, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
    context.setFillColor(NSColor.blue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    var preferences = DisplayPreferences()
    preferences.thumbnailSize = 140
    let store = InMemoryDisplayPreferencesStore(preferences)
    let scene = try Issue349AppScene(store: store, count: 1, folder: folder)
    let previous = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {},
        openDiagnostics: {}, windowController: { scene.controller })
    defer { NSApp.mainMenu = previous; withExtendedLifetime(menu) {}; scene.close() }
    let pipeline = ImageIOPipeline()
    scene.grid.thumbnailLoader = { entry, rootID, coverage, _ in
        let root = ItemIdentityRoot(id: rootID, url: entry.url.deletingLastPathComponent())
        let request = try await pipeline.request(for: entry.url, covering: coverage, identityRoot: root)
        return (request, try await pipeline.image(for: request))
    }
    scene.grid.setThumbnailsActive(true)
    func loadedImage() async throws -> CGImage {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            scene.settle()
            if let contents = try scene.tile().layer?.contents {
                try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
                return contents as! CGImage
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "issue349-thumbnail-deadline", code: 1)
    }
    let small = try await loadedImage()
    for _ in 0..<7 { try scene.key("+") }
    #expect(store.value.thumbnailSize == 280)
    let large = try await loadedImage()
    let tile = try scene.tile()
    #expect(large.width > small.width && large.height > small.height)
    #expect(CGFloat(large.width) >= tile.frame.width * scene.window.backingScaleFactor)
    #expect(CGFloat(large.height) >= tile.frame.height * scene.window.backingScaleFactor)
    #expect(scene.grid.currentItemID == scene.entries[0].itemID)
}

@MainActor func issue349ViewMenu() throws -> NSMenu {
    try #require(NSApp.mainMenu?.items.compactMap(\.submenu)
        .first { $0.items.contains { $0.representedObject as? String == CommandID.fit.rawValue } })
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue349RealGridMenuKeysAndSearchPriority() throws {
    let store = InMemoryDisplayPreferencesStore()
    let scene = try Issue349AppScene(store: store)
    let previous = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {},
        openDiagnostics: {}, windowController: { scene.controller })
    defer { NSApp.mainMenu = previous; withExtendedLifetime(menu) {}; scene.close() }
    let view = try issue349ViewMenu()
    let zoom = view.items.filter { ($0.representedObject as? String).flatMap(CommandID.init(rawValue:))?.commandKey != nil }
    #expect(zoom.count == 9)
    for item in zoom {
        let expected = item.keyEquivalentModifierMask.contains(.command) && item.keyEquivalent != "9"
        #expect(menu.validateMenuItem(item) == expected, "\(item.keyEquivalent),\(item.keyEquivalentModifierMask)")
    }
    for (key, expected) in [("+", 240.0), ("=", 260), ("-", 240), ("0", 220)] {
        try scene.key(key)
        #expect(store.value.thumbnailSize == expected)
        #expect(scene.grid.displayOptions.thumbnailSize == expected)
    }
    for (key, end) in [("+", 280.0), ("-", 140)] {
        for _ in 0..<10 { try scene.key(key) }
        #expect(store.value.thumbnailSize == end)
    }
    for size in [180.0, 220] {
        store.value.thumbnailSize = size
        scene.settle()
        let before = try scene.tile().frame
        for key in ["+", "=", "-", "0", "1"] {
            _ = view.performKeyEquivalent(with: try scene.event(key, command: false))
            scene.settle()
            #expect(store.value.thumbnailSize == size)
            #expect(try scene.tile().frame == before)
        }
        _ = try #require(NSApp.mainMenu).performKeyEquivalent(with: try scene.event("9"))
        #expect(store.value.thumbnailSize == size)
    }
    scene.shell.focusSearch()
    let editor = try #require(scene.shell.searchField.currentEditor() as? NSTextView)
    editor.string = "IMG"
    let size = store.value.thumbnailSize
    for key in ["+", "=", "-", "0", "9"] {
        #expect(try !#require(NSApp.mainMenu).performKeyEquivalent(with: scene.event(key)))
        #expect(store.value.thumbnailSize == size)
        #expect(scene.window.firstResponder === editor)
        #expect(editor.string == "IMG")
    }
    #expect(scene.window.makeFirstResponder(scene.grid.collectionView))
    try scene.key("+")
    #expect(store.value.thumbnailSize == size + 20)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue349TwoWindowsResizeWithoutLosingTheirCurrentSelection() throws {
    let suite = "mado.app349.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let a = try Issue349AppScene(store: store), b = try Issue349AppScene(store: store)
    let previous = NSApp.mainMenu
    var active = a.controller
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {},
        openDiagnostics: {}, windowController: { active })
    defer { NSApp.mainMenu = previous; withExtendedLifetime(menu) {}; a.close(); b.close() }
    for (scene, index) in [(a, 75), (b, 90)] {
        scene.controller.session.select(scene.entries[2].itemID)
        scene.controller.session.select(scene.entries[index].itemID, modifier: .command)
        scene.grid.synchronizeSelection(scene.controller.session.selection)
        scene.grid.restoreContentOffset(.zero)
    }
    let aSelection = a.controller.session.selection, bSelection = b.controller.session.selection
    for (scene, key) in [(a, "+"), (b, "-"), (a, "-"), (b, "0")] {
        active = scene.controller
        try scene.key(key)
        a.settle(); b.settle()
        #expect(a.controller.session.selection == aSelection && b.controller.session.selection == bSelection)
        #expect(a.grid.selection == aSelection && b.grid.selection == bSelection)
        #expect(a.grid.displayOptions.thumbnailSize == store.value.thumbnailSize)
        #expect(b.grid.displayOptions.thumbnailSize == store.value.thumbnailSize)
        for window in [a, b] {
            let current = try #require(window.grid.currentItemID)
            let index = try #require(window.grid.index(for: current))
            let cell = try #require(window.grid.collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
            let scroll = try #require(window.grid.collectionView.enclosingScrollView)
            var visible = scroll.contentView.documentVisibleRect
            visible.size.height -= scroll.contentInsets.bottom
            #expect(visible.insetBy(dx: -0.1, dy: -0.1).contains(cell.frame), "current \(index) is visible")
            let tile = try window.tile(index)
            #expect(abs(tile.frame.height - 188.16 * store.value.thumbnailSize / 220) < 0.02)
        }
    }
    #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == store.value)
}
