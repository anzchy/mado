import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// #114 / P3-11 WI-4: Settings 显示 edits the same three preferences as the page-15 grid Display panel
/// (owner: 「两者都做，共用一组偏好」).
@MainActor private func issue114SettingsPanel(_ store: any DisplayPreferencesStore) -> SettingsPanelWindow {
    SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: store),
        preferencesStore: store,
        defaults: UserDefaults(suiteName: "issue114-settings-\(UUID().uuidString)")!,
        updates: FakeUpdatePort())
}

@MainActor private func issue114SettingsView(_ id: String, in root: NSView?) -> NSView? {
    guard let root else { return nil }
    if root.accessibilityIdentifier() == id { return root }
    return root.subviews.lazy.compactMap { issue114SettingsView(id, in: $0) }.first
}

@MainActor private func issue114SettingsAX(_ view: NSView) -> String? {
    switch view.accessibilityValue() {
    case let number as NSNumber: number.stringValue
    case let string as String: string
    default: nil
    }
}

@MainActor private func issue114SettingsSend(_ control: NSControl) {
    _ = control.sendAction(control.action, to: control.target)
}

@MainActor private func issue114SettingsDisabled(in root: NSView) -> [NSControl] {
    let own = (root as? NSControl).map { $0.isEnabled ? [] : [$0] } ?? []
    return own + root.subviews.flatMap(issue114SettingsDisabled(in:))
}

@MainActor private func issue114SettingsTexts(in root: NSView) -> [String] {
    let own = (root as? NSTextField).map { [$0.stringValue] } ?? []
    return own + root.subviews.flatMap(issue114SettingsTexts(in:))
}

private let issue114SettingsMarkers = ["Coming Soon", "即将推出"]

@MainActor private struct Issue114SettingsControls {
    let panel: SettingsPanelWindow
    let size: NSSlider, names: NSButton, fill: NSButton, fit: NSButton
    init(_ panel: SettingsPanelWindow) throws {
        self.panel = panel
        panel.select(.display)
        let root = try #require(panel.window.contentView)
        size = try #require(issue114SettingsView("settings.display.size", in: root) as? NSSlider)
        names = try #require(issue114SettingsView("settings.display.names", in: root) as? NSButton)
        fill = try #require(issue114SettingsView("settings.display.fit.0", in: root) as? NSButton)
        fit = try #require(issue114SettingsView("settings.display.fit.1", in: root) as? NSButton)
    }
    func slide(_ value: Double) {
        size.doubleValue = value
        issue114SettingsSend(size)
    }
    /// The fit pair reads as a radio group: the selected button is on with AX value "1", the other off with "0".
    func expectFit(_ expected: ThumbnailFit, _ step: String) {
        let selected = expected == .fit ? fit : fill, other = expected == .fit ? fill : fit
        #expect(selected.state == .on, "\(step): selected fit button on")
        #expect(issue114SettingsAX(selected) == "1", "\(step): selected fit AX value")
        #expect(other.state == .off, "\(step): other fit button off")
        #expect(issue114SettingsAX(other) == "0", "\(step): other fit AX value")
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsEntryPointsEnabledNoBadge() throws {
    let panel = issue114SettingsPanel(InMemoryDisplayPreferencesStore())
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let expected: [String: EntryPoint] = [
        "settings.display.size": .settingsDisplayThumbnailSize,
        "settings.display.names": .settingsDisplayFileNames,
        "settings.display.fit.0": .settingsDisplayFitMode,
        "settings.display.fit.1": .settingsDisplayFitMode,
    ]
    panel.select(.display)
    for (id, entry) in expected {
        let control = try #require(issue114SettingsView(id, in: root) as? NSControl)
        #expect(control.isEnabled, "\(id) enabled")
        #expect(!control.refusesFirstResponder, "\(id) focusable")
        #expect(control.action != nil && control.target != nil, "\(id) has an action")
        let label = control.accessibilityLabel() ?? ""
        for marker in issue114SettingsMarkers { #expect(!label.contains(marker), "\(id) label \(label)") }
        #expect(panel.entryPoint(for: control) == entry, "\(id)")
        #expect(entry.state == .implemented, "\(id)")
        #expect(entry.isEnabled && entry.isFocusable, "\(id)")
    }
    let pane = try #require(issue114SettingsView("settings.pane.display", in: root))
    for text in issue114SettingsTexts(in: pane) {
        for marker in issue114SettingsMarkers + [String(localized: "Coming Soon")] {
            #expect(!text.contains(marker), "display pane text \(text)")
        }
    }
    #expect(issue114SettingsTexts(in: pane).contains(String(localized:
        "These are the same preferences as the grid footer Display panel; changes will sync immediately.")))
    let disabled = issue114SettingsDisabled(in: root)
    #expect(Set(disabled.compactMap { $0.accessibilityIdentifier() }) == Set(CaptureDeferredSettingsControls.tickets.keys))
    #expect(CaptureDeferredSettingsControls.unexpectedDisabledIDs(disabled).isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsControlsWriteStore() throws {
    let store = InMemoryDisplayPreferencesStore()
    let panel = issue114SettingsPanel(store)
    defer { panel.window.close() }
    let c = try Issue114SettingsControls(panel)
    #expect(c.size.minValue == 140 && c.size.maxValue == 280)
    #expect(c.size.numberOfTickMarks == 15)
    #expect(c.size.allowsTickMarkValuesOnly)

    c.slide(173)
    #expect(store.value.thumbnailSize == 170)
    #expect(c.size.doubleValue == 170)

    #expect(c.names.state == .on, "default shows names")
    c.names.performClick(nil)
    #expect(store.value.showFileNames == false)
    #expect(c.names.state == .off)
    c.names.performClick(nil)
    #expect(store.value.showFileNames == true)
    #expect(c.names.state == .on)

    c.expectFit(.fill, "default")
    c.fit.performClick(nil)
    #expect(store.value.thumbnailFit == .fit)
    c.expectFit(.fit, "fit.1")
    c.fit.performClick(nil)
    #expect(store.value.thumbnailFit == .fit, "re-clicking the selected fit button is a no-op")
    c.expectFit(.fit, "fit.1 again")
    c.fill.performClick(nil)
    #expect(store.value.thumbnailFit == .fill)
    c.expectFit(.fill, "fit.0")
}

/// Adversary round 1: every write is read-modify-write on the store's current value.
@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsControlsPreserveConcurrentFields() throws {
    let store = InMemoryDisplayPreferencesStore()
    let panel = issue114SettingsPanel(store)
    defer { panel.window.close() }
    let c = try Issue114SettingsControls(panel)
    var external = store.value
    external.gridSidebarWidth = 300
    external.appearance = .dark
    store.value = external

    var expected = store.value
    c.slide(173)
    expected.thumbnailSize = 170
    #expect(store.value == expected, "slider")

    var concurrent = store.value
    concurrent.loopThroughImages = true
    concurrent.gridSidebarVisible = false
    store.value = concurrent
    expected = store.value
    c.names.performClick(nil)
    expected.showFileNames = false
    #expect(store.value == expected, "names")

    concurrent = store.value
    concurrent.alwaysShowTools = true
    concurrent.folderSortDirection = .descending
    store.value = concurrent
    expected = store.value
    c.fit.performClick(nil)
    expected.thumbnailFit = .fit
    #expect(store.value == expected, "fit")
    #expect(store.value.gridSidebarWidth == 300 && store.value.appearance == .dark)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsSliderClampsAndSnaps() throws {
    let store = InMemoryDisplayPreferencesStore()
    let panel = issue114SettingsPanel(store)
    defer { panel.window.close() }
    let c = try Issue114SettingsControls(panel)
    for (input, output) in [(135.0, 140.0), (285, 280), (146, 150)] {
        c.slide(input)
        #expect(store.value.thumbnailSize == output, "\(input) in store")
        #expect(c.size.doubleValue == output, "\(input) on slider")
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsReflectExternalWrites() throws {
    let store = InMemoryDisplayPreferencesStore(DisplayPreferences(alwaysShowTools: true, appearance: .light))
    let panel = issue114SettingsPanel(store)
    defer { panel.window.close() }
    let c = try Issue114SettingsControls(panel)
    let root = try #require(panel.window.contentView)
    let light = try #require(issue114SettingsView("settings.appearance.light", in: root) as? NSButton)
    let tools = try #require(issue114SettingsView("settings.always-show-tools", in: root) as? NSButton)

    var value = store.value
    value.thumbnailSize = 260
    value.showFileNames = false
    value.thumbnailFit = .fit
    store.value = value
    #expect(c.size.doubleValue == 260)
    #expect(c.names.state == .off)
    c.expectFit(.fit, "external 260/off/fit")

    value = store.value
    value.thumbnailSize = 220
    value.showFileNames = true
    value.thumbnailFit = .fill
    store.value = value
    #expect(c.size.doubleValue == 220)
    #expect(c.names.state == .on)
    c.expectFit(.fill, "external defaults")

    #expect(light.state == .on && issue114SettingsAX(light) == "1", "appearance unchanged")
    #expect(tools.state == .on, "always-show-tools unchanged")
    #expect(store.value.appearance == .light && store.value.alwaysShowTools)
}

@MainActor private final class Issue114SettingsShell {
    let shell: GridShellView
    let grid: GridBrowserView
    let window: NSWindow
    let count = 12
    init(_ store: any DisplayPreferencesStore) throws {
        _ = NSApplication.shared
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), preferencesStore: store)
        shell.appearance = NSAppearance(named: .aqua)
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        grid.autoresizingMask = [.width, .height]
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        let scrollView = try #require(grid.collectionView.enclosingScrollView)
        scrollView.scrollerStyle = .overlay
        scrollView.tile()
        let url = URL(fileURLWithPath: "/tmp/mado-settings-114")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: url)
        let entries = (0..<count).map { FolderEntry(url: url.appendingPathComponent("IMG_\($0).jpg"), root: root) }
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: url, generation: 1),
            entries: entries, isComplete: true), selectedItemID: nil)
        grid.activate()
        settle()
    }
    func settle() {
        shell.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
    }
    var columns: Int {
        let layout = grid.collectionView.collectionViewLayout!
        guard let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) else { return 0 }
        return (0..<count).filter { index in
            layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)).map {
                abs($0.frame.minY - first.frame.minY) < 0.5 } ?? false
        }.count
    }
}

/// AC-4: one real UserDefaults suite; each surface is built on a freshly loaded store, as after a relaunch.
@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsCrossSurfacePersistence() throws {
    let suite = "issue114-cross-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let seed = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    var preload = seed.value
    preload.appearance = .dark
    preload.loopThroughImages = true
    preload.gridSidebarVisible = false
    seed.value = preload

    // A: grid Display panel → relaunched Settings.
    let store1 = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let first = try Issue114SettingsShell(store1)
    defer { first.window.close() }
    first.shell.setDisplayPanelOpen(true)
    let panel = first.shell.displayPanel
    panel.sizeSlider.doubleValue = 260
    issue114SettingsSend(panel.sizeSlider)
    panel.namesCheckbox.state = .off
    issue114SettingsSend(panel.namesCheckbox)
    panel.fitPopup.selectItem(at: 1)
    issue114SettingsSend(panel.fitPopup)
    #expect(store1.value.thumbnailSize == 260 && !store1.value.showFileNames && store1.value.thumbnailFit == .fit)

    let store2 = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let settings = issue114SettingsPanel(store2)
    defer { settings.window.close() }
    let c = try Issue114SettingsControls(settings)
    #expect(c.size.doubleValue == 260, "A: Settings slider")
    #expect(c.names.state == .off, "A: Settings names")
    c.expectFit(.fit, "A: Settings fit")

    // B: Settings → relaunched grid Display panel and grid.
    c.slide(150)
    c.names.performClick(nil)
    c.fill.performClick(nil)
    #expect(store2.value.thumbnailSize == 150 && store2.value.showFileNames && store2.value.thumbnailFit == .fill)

    let store3 = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let second = try Issue114SettingsShell(store3)
    defer { second.window.close() }
    second.shell.setDisplayPanelOpen(true)
    second.settle()
    let reopened = second.shell.displayPanel
    #expect(reopened.sizeSlider.doubleValue == 150, "B: panel slider")
    #expect(reopened.namesCheckbox.state == .on, "B: panel names")
    #expect(reopened.fitPopup.indexOfSelectedItem == 0, "B: panel fit")
    #expect(second.grid.displayOptions == GridDisplayOptions(thumbnailSize: 150, showFileNames: true, fit: .fill))
    #expect(second.columns == 7, "B: 1280 hidden sidebar at 150")
    #expect(store3.value.appearance == .dark && store3.value.loopThroughImages, "unrelated fields survive")
}

private struct Issue114SettingsBookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        guard let path = String(data: data, encoding: .utf8) else { throw FileAccessError.corruptStore }
        return ResolvedBookmark(url: URL(fileURLWithPath: path), stale: false)
    }
}

private final class Issue114SettingsScanner: FolderScanning, @unchecked Sendable {
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try await emit(files.map { FolderEntry(url: $0, root: root) })
    }
}

@MainActor private final class Issue114SettingsMotion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue114SettingsDescendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(issue114SettingsDescendants)
}

/// The relaunched window's grid uses the stored options, and Esc closes the panel through the real
/// CanvasWindowController key path (inspector hidden), returning focus to the Display button.
@Test(.timeLimit(.minutes(3))) @MainActor func issue114SettingsCanvasDisplayPanelEscAndRelaunchedGrid() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("issue114-canvas-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    let folder = base.appendingPathComponent("Shown")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 1...6 { try data.write(to: folder.appendingPathComponent("DSC_000\(index).png")) }

    let suite = "issue114-canvas-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let seed = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    var preload = seed.value
    preload.thumbnailSize = 260
    preload.showFileNames = false
    preload.thumbnailFit = .fit
    seed.value = preload
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)

    let adapter = Issue114SettingsBookmarks()
    let access = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue114")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue114SettingsMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    controller.folderScanningOverride = Issue114SettingsScanner()
    window.setContentSize(NSSize(width: 1280, height: 772))
    controller.showWindow(nil)
    window.orderFrontRegardless()
    func waitUntil(_ condition: () -> Bool, fileID: String = #fileID, line: Int = #line) async throws {
        try await MadoAppTests.waitUntil(fileID: fileID, line: line, between: { window.update() }, condition)
    }

    controller.openGrantedFolder(folder)
    try await waitUntil { controller.gridSearchAvailable }
    #expect(!controller.inspectorVisible)
    let shell = try #require(window.contentView?.subviews.compactMap { $0 as? GridShellView }.first)
    let grid = try #require(shell.mainContent.subviews.compactMap { $0 as? GridBrowserView }.first)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(grid.displayOptions == GridDisplayOptions(thumbnailSize: 260, showFileNames: false, fit: .fit))

    func photoItems() -> [GridPhotoItem] { grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem } }
    func tile(_ item: GridPhotoItem) -> NSView? {
        issue114SettingsDescendants(item.view).first { $0.layer?.contentsGravity == .resizeAspect }
    }
    try await waitUntil {
        let items = photoItems()
        return items.count == 6 && items.allSatisfy { tile($0)?.layer?.contents != nil }
    }
    for item in photoItems() {
        let tileView = try #require(tile(item), "\(item.filename) aspect-fit tile")
        #expect(abs(tileView.frame.height + 8 - item.view.bounds.height) < 0.01, "\(item.filename) item = tile + 8")
        let visibleNames = issue114SettingsDescendants(item.view).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == item.filename && !$0.isHiddenOrHasHiddenAncestor }
        #expect(visibleNames.isEmpty, "\(item.filename) name hidden")
    }

    let button = shell.displayButton
    _ = button.sendAction(button.action, to: button.target)
    #expect(shell.isDisplayPanelOpen)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53))
    window.sendEvent(escape)
    #expect(!shell.isDisplayPanelOpen, "Esc closes the Display panel")
    #expect(window.firstResponder === button, "focus returns to the Display button")
}

/// #114 fix round 1 (opus L1): the Settings note says changes sync immediately. Within the app both surfaces observe
/// the one store, so with Settings and the grid panel open together each reflects the other's change at once.
@MainActor @Test(.timeLimit(.minutes(3))) func issue114SettingsAndOpenPanelSyncInProcess() throws {
    let store = InMemoryDisplayPreferencesStore()
    let grid = try Issue114SettingsShell(store)
    defer { grid.window.close() }
    grid.shell.setDisplayPanelOpen(true)
    let panel = grid.shell.displayPanel
    let settings = issue114SettingsPanel(store)
    defer { settings.window.close() }
    let c = try Issue114SettingsControls(settings)

    c.slide(260)
    c.names.performClick(nil)
    c.fit.performClick(nil)
    grid.settle()
    #expect(panel.sizeSlider.doubleValue == 260 && panel.namesCheckbox.state == .off)
    #expect(panel.fitPopup.indexOfSelectedItem == 1)
    // 1280 pt window, sidebar shown: 1084 pt content, insets 24, gap 16 → ⌊1052 / 276⌋ = 3 (4 at the default 220).
    #expect(grid.columns == 3)

    panel.sizeSlider.doubleValue = 150
    issue114SettingsSend(panel.sizeSlider)
    panel.namesCheckbox.state = .on
    issue114SettingsSend(panel.namesCheckbox)
    panel.fitPopup.selectItem(at: 0)
    issue114SettingsSend(panel.fitPopup)
    #expect(c.size.doubleValue == 150 && c.names.state == .on)
    c.expectFit(.fill, "panel → open Settings")
    #expect(grid.shell.isDisplayPanelOpen)
}
