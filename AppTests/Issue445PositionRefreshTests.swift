import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue445PositionMotion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue445PositionView<T: NSView>(_ root: NSView?, as type: T.Type) -> T? {
    guard let root else { return nil }
    if let match = root as? T { return match }
    return root.subviews.lazy.compactMap { issue445PositionView($0, as: type) }.first
}

@MainActor private func issue445PositionItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in [item] + (item.submenu.map(issue445PositionItems) ?? []) }
}

@MainActor private final class Issue445PositionScene {
    let base: URL
    let folder: URL
    let root: AccessRootID
    let controller: CanvasWindowController
    let window: NSWindow
    let menu: CommandMenu
    let previousMenu: NSMenu?

    init(names: [String]) async throws {
        _ = NSApplication.shared
        previousMenu = NSApp.mainMenu
        base = FileManager.default.temporaryDirectory.appendingPathComponent("issue445-position-\(UUID().uuidString)")
        folder = base.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let png = try Data(contentsOf: fixture)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        for name in names {
            try (name.hasSuffix(".jpg") ? jpeg : png).write(to: folder.appendingPathComponent(name))
        }
        let scope = SystemSecurityScope()
        let files = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue445-position")
        root = try await files.grant(folder: folder)
        let services = AccessServices(files: files,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let store = InMemoryDisplayPreferencesStore()
        var preferences = store.value
        preferences.alwaysShowTools = true
        store.value = preferences
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue445PositionMotion()))
        self.controller = controller
        window = try #require(controller.window)
        menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {}, openDiagnostics: {},
            windowController: { controller })
        window.setContentSize(NSSize(width: 1280, height: 800))
    }
    func close() {
        controller.session.endFolderScan()
        window.close()
        NSApp.mainMenu = previousMenu
        try? FileManager.default.removeItem(at: base)
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        try await MadoAppTests.waitUntil(between: { self.window.update() }, condition)
    }
    func filenameField() throws -> NSTextField {
        let overlay = try #require(issue445PositionView(window.contentView, as: ViewerChromeOverlay.self))
        return try #require(overlay.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "chrome.filename" })
    }
    /// A wrong position is a fast assertion failure, not a100-second condition-wait timeout.
    /// Only native window updates/run-loop work can refresh the field; this helper never calls chrome.refresh.
    func expectPosition(_ expected: String) async throws -> Bool {
        let field = try filenameField()
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
        window.update()
        while (field.stringValue != expected || field.accessibilityValue() as? String != expected), clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
            window.update()
        }
        #expect(field.stringValue == expected)
        #expect(field.accessibilityValue() as? String == expected)
        return field.stringValue == expected && field.accessibilityValue() as? String == expected
    }
    func invokeFolderMenu(_ identifier: String) throws {
        let main = try #require(NSApp.mainMenu)
        main.update()
        // NSMenu.update runs AppKit's normal dynamic-menu population/validation path, including Extensions.
        func update(_ menu: NSMenu) {
            menu.update()
            for item in menu.items { if let submenu = item.submenu { update(submenu) } }
        }
        update(main)
        if identifier.hasPrefix("folder.extension."),
           !issue445PositionItems(main).contains(where: { $0.accessibilityIdentifier() == identifier }) {
            // Extensions is lazy: NSMenu.update alone does not enter its native opening lifecycle.
            // Briefly track the real submenu so AppKit, rather than this test, sends menuNeedsUpdate.
            let extensions = try #require(issue445PositionItems(main)
                .first { $0.accessibilityIdentifier() == "folder.extensions.menu" }?.submenu)
            let cancel = Timer(timeInterval: 0.01, target: extensions,
                selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(cancel, forMode: .eventTracking)
            RunLoop.main.add(cancel, forMode: .common)
            defer { cancel.invalidate() }
            _ = extensions.popUp(positioning: nil, at: NSPoint(x: 16, y: 16), in: window.contentView)
        }
        let item = try #require(issue445PositionItems(main).first { $0.accessibilityIdentifier() == identifier })
        try #require(menu.validateMenuItem(item))
        try #require(item.isEnabled)
        try #require(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        try #require(menu.validateMenuItem(item))
        try #require(item.state == .on)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue445SameSourceSortAndFilterMenuRefreshPositionWithoutReopening() async throws {
    let scene = try await Issue445PositionScene(names: ["a.png", "b.jpg", "c.jpg"])
    defer { scene.close() }
    let controller = scene.controller
    controller.open(scene.folder.appendingPathComponent("a.png"), accessRequest: .root(scene.root, file: scene.folder.appendingPathComponent("a.png")))
    try await scene.waitUntil {
        controller.session.folderScan?.snapshot?.isComplete == true && controller.session.imageLoader.phase == .settled && controller.hasImage
    }
    try #require(controller.session.previewSet == nil)
    try #require(controller.session.filePreviewSet == nil)
    // Prime the ordinary window update while identity/source are stable, before the menu projection changes.
    guard try await scene.expectPosition("a.png  1 / 3") else { return }
    let scan = try #require(controller.session.folderScan)
    let version = try #require(scan.sourceSnapshot?.version)
    let generation = controller.session.imageLoader.generation
    let presented = try #require(controller.session.imageLoader.presented?.key)
    func expectUnchangedSourceAndImage() {
        #expect(scan.sourceSnapshot?.version == version)
        #expect(controller.session.imageLoader.generation == generation)
        #expect(controller.session.imageLoader.presented?.key == presented)
        #expect(controller.session.imageLoader.presented?.fileURL.lastPathComponent == "a.png")
        #expect(controller.session.previewSet == nil)
    }

    try scene.invokeFolderMenu("folder.order.descending.menu")
    #expect(controller.session.folderConditions.direction == .descending)
    #expect(scan.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["c.jpg", "b.jpg", "a.png"])
    expectUnchangedSourceAndImage()
    _ = try await scene.expectPosition("a.png  3 / 3")
    expectUnchangedSourceAndImage()

    try scene.invokeFolderMenu("folder.extension.png.menu")
    #expect(controller.session.folderConditions.selectedExtensions == ["png"])
    #expect(scan.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["a.png"])
    expectUnchangedSourceAndImage()
    _ = try await scene.expectPosition("a.png  1 / 1")
    expectUnchangedSourceAndImage()

    try scene.invokeFolderMenu("folder.extension.all.menu")
    #expect(controller.session.folderConditions.selectedExtensions == nil)
    #expect(scan.snapshot?.navigationEntries.count == 3)
    expectUnchangedSourceAndImage()
    _ = try await scene.expectPosition("a.png  3 / 3")
    try scene.invokeFolderMenu("folder.order.ascending.menu")
    #expect(scan.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["a.png", "b.jpg", "c.jpg"])
    _ = try await scene.expectPosition("a.png  1 / 3")
    expectUnchangedSourceAndImage()
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue445SelectedThreeOfTwelvePreviewPagesInSetOrderAndPositions() async throws {
    let names = (0..<12).map { String(format: "%03d.png", $0) }
    let scene = try await Issue445PositionScene(names: names)
    defer { scene.close() }
    let controller = scene.controller
    controller.openGrantedFolder(scene.folder)
    try await scene.waitUntil { controller.gridSearchAvailable }
    let grid = try #require(issue445PositionView(scene.window.contentView, as: GridBrowserView.self))
    let ids = grid.displayedItemIDs
    try #require(ids.count == 12)
    let selected = [ids[1], ids[5], ids[9]]
    // Reverse click order must not become paging order: the frozen set follows the folder's order.
    controller.session.select(ids[9])
    controller.session.select(ids[5], modifier: .command)
    controller.session.select(ids[1], modifier: .command)
    controller.session.focus(ids[1])
    grid.synchronizeSelection(controller.session.selection)
    try #require(controller.route(.preview, from: .key))
    try #require(controller.session.previewSet?.itemIDs == selected)
    try #require(controller.session.previewSet?.currentItemID == ids[1])
    try await scene.waitUntil {
        controller.session.imageLoader.phase == .settled && controller.session.imageLoader.presented?.fileURL.lastPathComponent == "001.png"
    }
    _ = try await scene.expectPosition("001.png  1 / 3")
    for (command, index, name, position) in [(CommandID.next, 5, "005.png", "2 / 3"),
        (.next, 9, "009.png", "3 / 3"), (.previous, 5, "005.png", "2 / 3")] {
        try #require(controller.route(command, from: .key))
        try #require(controller.session.previewSet?.currentItemID == ids[index])
        try #require(controller.session.previewSet?.itemIDs == selected)
        try await scene.waitUntil {
            controller.session.imageLoader.phase == .settled && controller.session.imageLoader.presented?.fileURL.lastPathComponent == name
        }
        #expect(controller.session.imageLoader.fileURL?.lastPathComponent == name)
        _ = try await scene.expectPosition("\(name)  \(position)")
    }
}
