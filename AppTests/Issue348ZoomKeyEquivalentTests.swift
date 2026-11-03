import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private final class Issue348MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private let issue348ZoomIDs: [CommandID] = [.fit, .actualPixels, .zoomIn, .zoomOut]

/// A real window controller showing an 800×400 image, with the real main menu installed.
/// The window stays ordered out, so menu zoom anchors at the centre whatever the real mouse does.
@MainActor private struct Issue348Scene {
    let controller: CanvasWindowController
    let window: NSWindow
    let canvas: CanvasView
    let menu: CommandMenu
    let previousMenu: NSMenu?

    init() throws {
        _ = NSApplication.shared
        previousMenu = NSApp.mainMenu
        let unavailable = Task<AccessServices, Error> { throw CancellationError() }
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
            motionPolicy: MotionPolicy(source: Issue348MotionSource()))
        self.controller = controller
        window = try #require(controller.window)
        menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(), openWithoutWindow: {},
            openSettings: {}, openDiagnostics: {}, windowController: { controller })
        let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        controller.installImage(DecodedImage(image: try #require(context.makeImage()),
            sourcePixelSize: CGSize(width: 800, height: 400)), fileURL: URL(fileURLWithPath: "/issue348/wide.png"))
        window.orderOut(nil)
        func descendants(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap(descendants)
        }
        canvas = try #require(descendants(window.contentView).compactMap { $0 as? CanvasView }.first)
        try #require(controller.session.isEnabled(.zoomIn))
    }

    func close() {
        NSApp.mainMenu = previousMenu
        withExtendedLifetime(menu) {}
        window.close()
    }

    var viewMenu: NSMenu? {
        NSApp.mainMenu?.items.compactMap(\.submenu)
            .first { $0.items.contains { $0.representedObject as? String == CommandID.fit.rawValue } }
    }

    func event(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// ⌘ forms take the real main-menu path.
    func command(_ characters: String, _ keyCode: UInt16, _ extra: NSEvent.ModifierFlags = []) throws -> Bool {
        try #require(NSApp.mainMenu).performKeyEquivalent(with: try event(characters, keyCode, extra.union(.command)))
    }

    /// Bare forms reach the same View items; the unchanged key-window gate in front of them is device smoke.
    func bare(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> Bool {
        try #require(viewMenu).performKeyEquivalent(with: try event(characters, keyCode, flags))
    }

    func snapshot() throws -> (CanvasZoomMode, Data?) {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width),
            pixelsHigh: Int(canvas.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = canvas.bounds.size
        rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        return (controller.session.zoomMode, rep.tiffRepresentation)
    }

    func zoomItems() -> [NSMenuItem] {
        (viewMenu?.items ?? []).filter { item in
            issue348ZoomIDs.contains { item.representedObject as? String == $0.rawValue }
        }
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func viewMenuShowsCmdZoomEquivalents() throws {
    let scene = try Issue348Scene()
    defer { scene.close() }
    let view = try #require(scene.viewMenu)
    let expected: [(CommandID, String, String)] = [(.fit, "9", "Fit"), (.actualPixels, "0", "Actual Pixels"),
                                                   (.zoomIn, "+", "Zoom In"), (.zoomOut, "-", "Zoom Out")]
    var visible: [NSMenuItem] = []
    for (id, key, english) in expected {
        let item = try #require(view.items.first { $0.representedObject as? String == id.rawValue })
        visible.append(item)
        #expect(item.keyEquivalent == key, "\(id)")
        #expect(item.keyEquivalentModifierMask == [.command], "\(id)")
        #expect(item.title == id.menuTitle, "\(id)")
        if Locale.current.language.languageCode == .english { #expect(item.title == english) }
        #expect(!item.isHidden, "\(id)")
    }
    let hidden = view.items.filter(\.isHidden)
    #expect(hidden.count == 5)
    let alternates = Set(hidden.map { "\($0.representedObject as? String ?? "?") \($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue)" })
    #expect(alternates == ["fit 0 0", "actualPixels 1 0", "zoomIn + 0", "zoomOut - 0",
                           "zoomIn = \(NSEvent.ModifierFlags.command.rawValue)"])
    for item in hidden {
        #expect(item.allowsKeyEquivalentWhenHidden, "\(item.keyEquivalent)")
        let shown = try #require(visible.first { $0.representedObject as? String == item.representedObject as? String })
        #expect(item.action == shown.action)
        #expect(item.target === shown.target)
    }
    let commandItems = view.items.filter { $0.representedObject is String && !$0.isHidden }
    let lastVisible = try #require(commandItems.map { view.index(of: $0) }.max())
    let firstHidden = try #require(hidden.map { view.index(of: $0) }.min())
    #expect(lastVisible < firstHidden)
    let ids = view.items.map { $0.accessibilityIdentifier() }.filter { !$0.isEmpty }
    #expect(Set(ids).count == ids.count)
    var seen: [String: String] = [:]
    func collect(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { collect(submenu) }
            guard !item.keyEquivalent.isEmpty else { continue }
            let mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            let key = "\(item.keyEquivalent) \(mask.rawValue)"
            #expect(seen[key] == nil, "\(item.title) shares \(key) with \(seen[key] ?? "")")
            seen[key] = item.title
        }
    }
    collect(try #require(NSApp.mainMenu))
}

@Test(.timeLimit(.minutes(3))) @MainActor func cmdZoomKeysMatchBareKeysThroughMainMenu() throws {
    let scene = try Issue348Scene()
    defer { scene.close() }
    #expect(scene.window.makeFirstResponder(scene.canvas))
    // (⌘ characters, extra modifier, bare characters, bare modifier, key code)
    let steps: [(String, NSEvent.ModifierFlags, String, NSEvent.ModifierFlags, UInt16)] = [
        ("+", .shift, "+", .shift, 24), ("+", .shift, "+", .shift, 24), ("-", [], "-", [], 27),
        ("0", [], "1", [], 18), ("=", [], "+", .shift, 24), ("9", [], "0", [], 29), ("0", [], "1", [], 18),
        ("-", [], "-", [], 27),
    ]
    var commandRun: [(CanvasZoomMode, Data?)] = []
    scene.controller.route(.fit, from: .button)
    for (index, step) in steps.enumerated() {
        let code: UInt16 = step.0 == "0" ? 29 : step.0 == "9" ? 25 : step.4
        #expect(try scene.command(step.0, code, step.1), "⌘\(step.0) at step \(index)")
        commandRun.append(try scene.snapshot())
        if index == 3 { #expect(scene.controller.session.zoomMode == .actualPixels, "⌘0 is Actual Pixels") }
    }
    var bareRun: [(CanvasZoomMode, Data?)] = []
    scene.controller.route(.fit, from: .button)
    for (index, step) in steps.enumerated() {
        #expect(try scene.bare(step.2, step.4, step.3), "\(step.2) at step \(index)")
        bareRun.append(try scene.snapshot())
    }
    #expect(commandRun.count == bareRun.count)
    for (index, (command, bare)) in zip(commandRun, bareRun).enumerated() {
        #expect(command.0 == bare.0, "mode at step \(index)")
        #expect(command.1 == bare.1, "pixels at step \(index)")
    }
    let modes = commandRun.map(\.0)
    #expect(modes.contains(.fit) && modes.contains(.actualPixels))
    let custom = Set(modes.compactMap { if case .custom(let zoom) = $0 { zoom } else { nil } })
    #expect(custom.count >= 2)
}

@Test(.timeLimit(.minutes(3))) @MainActor func bareZoomKeysStillWorkWithToolFocus() throws {
    let scene = try Issue348Scene()
    defer { scene.close() }
    scene.controller.session.setInspectorVisible(true)
    scene.window.contentView?.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(descendants)
    }
    let close = try #require(descendants(scene.window.contentView)
        .first { $0.accessibilityIdentifier() == "inspector.close" })
    #expect(scene.window.makeFirstResponder(close))
    let session = scene.controller.session
    #expect(try scene.bare("1", 18))
    #expect(session.zoomMode == .actualPixels)
    #expect(try scene.bare("0", 29))
    #expect(session.zoomMode == .fit, "bare 0 stays Fit")
    #expect(try scene.command("0", 29))
    #expect(session.zoomMode == .actualPixels, "⌘0 is Actual Pixels")
    scene.controller.route(.fit, from: .button)
    let fitted = try scene.snapshot().1
    #expect(try scene.bare("+", 24, .shift))
    guard case .custom(let zoomed) = session.zoomMode else {
        Issue.record("bare + leaves a custom zoom, got \(session.zoomMode)")
        return
    }
    #expect(try scene.snapshot().1 != fitted)
    #expect(try scene.bare("-", 27))
    if case .custom(let out) = session.zoomMode { #expect(out < zoomed) } else { #expect(session.zoomMode == .fit) }
    let before = try scene.snapshot()
    #expect(try !scene.bare("9", 25))
    #expect(try !scene.command("1", 18))
    let after = try scene.snapshot()
    #expect(after.0 == before.0)
    #expect(after.1 == before.1)
    #expect(scene.window.firstResponder === close)
}

@Test(.timeLimit(.minutes(3))) @MainActor func zoomItemsDisabledInGrid() throws {
    let scene = try Issue348Scene()
    defer { scene.close() }
    let items = scene.zoomItems()
    #expect(items.count == 9)
    for item in items { #expect(scene.menu.validateMenuItem(item), "viewer \(item.keyEquivalent)") }
    let item = ItemID.rootRelative(rootID: AccessRootID(), relativePath: "wide.png")
    scene.controller.session.beginBrowsing(items: [item], sourceVersion: .init(1), scrollAnchor: item)
    scene.controller.showGrid()
    let before = scene.controller.session.zoomMode
    for item in items { #expect(!scene.menu.validateMenuItem(item), "Grid \(item.keyEquivalent)") }
    // AppKit consumes a disabled item's key equivalent without running it; what matters is that nothing zooms.
    _ = try scene.command("0", 29)
    #expect(scene.controller.session.zoomMode == before)
}

@Test(.timeLimit(.minutes(3))) @MainActor func textFieldKeepsCmdZoomKeys() throws {
    let scene = try Issue348Scene()
    defer { scene.close() }
    let session = scene.controller.session
    #expect(scene.window.makeFirstResponder(scene.canvas))
    #expect(try scene.command("0", 29))
    #expect(session.zoomMode == .actualPixels)
    scene.controller.route(.fit, from: .button)

    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
    field.stringValue = "abc"
    scene.window.contentView?.addSubview(field)
    #expect(scene.window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(scene.window.firstResponder === editor)
    let before = try scene.snapshot()
    let zoomKeys: [(String, UInt16, NSEvent.ModifierFlags)] = [("0", 29, []), ("9", 25, []), ("+", 24, .shift),
                                                              ("=", 24, []), ("-", 27, [])]
    for (characters, code, extra) in zoomKeys {
        #expect(try !scene.command(characters, code, extra), "⌘\(characters) belongs to the field")
        let now = try scene.snapshot()
        #expect(now.0 == before.0)
        #expect(now.1 == before.1)
        #expect(scene.window.firstResponder === editor)
    }
    // Other ⌘ keys still reach the menu while the field edits.
    let inspector = scene.controller.inspectorVisible
    #expect(try scene.command("i", 34))
    #expect(scene.controller.inspectorVisible != inspector)
    if scene.window.firstResponder !== editor { #expect(scene.window.makeFirstResponder(field)) }
    #expect(try scene.command("a", 0))
    // Select All is nil-targeted and goes to the key window, which AppTests do not have; the guard
    // letting ⌘A through is the assertion here, the selection itself is device smoke.

    // Over the whole real menu, the field claims exactly the five ⌘ zoom keys.
    for (characters, code, extra) in zoomKeys {
        #expect(CommandMainMenu.defersToTextField(try scene.event(characters, code, extra.union(.command))))
    }
    var checked = 0
    func check(_ menu: NSMenu) throws {
        for item in menu.items {
            if let submenu = item.submenu { try check(submenu) }
            guard !item.keyEquivalent.isEmpty, !item.isHidden else { continue }
            if let raw = item.representedObject as? String, let id = CommandID(rawValue: raw),
               issue348ZoomIDs.contains(id) { continue }
            let event = try scene.event(item.keyEquivalent, 0, item.keyEquivalentModifierMask)
            #expect(!CommandMainMenu.defersToTextField(event), "\(item.title)")
            checked += 1
        }
    }
    try check(try #require(NSApp.mainMenu))
    #expect(checked > 10)
}
