import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private final class Issue344MenuMotion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor private final class Issue344MenuInput: ViewerInputHost {
    var opened: [URL] = []
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) { opened.append(url) }
    func showInputNotice(_ notice: ViewerInputNotice) {}
    func promptForInputFolder(_ folder: URL) {}
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue344InstalledLoopMenuUsesSharedPreferenceAcrossGridPreviewAndFinder() async throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let store = InMemoryDisplayPreferencesStore()
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let first = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
        accessServices: unavailable, motionPolicy: MotionPolicy(source: Issue344MenuMotion()))
    let second = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
        accessServices: unavailable, motionPolicy: MotionPolicy(source: Issue344MenuMotion()))
    var activeController: CanvasWindowController? = first
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {}, openDiagnostics: {},
        windowController: { activeController })
    defer {
        first.window?.close(); second.window?.close()
        NSApp.mainMenu = previousMenu
        withExtendedLifetime(menu) {}
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let files = [base.appendingPathComponent("a.png"), base.appendingPathComponent("b.png")]
    for file in files { try Data([1]).write(to: file) }
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue344-menu")
    let root = try await access.grant(folder: base)
    let scan = FolderScanCoordinator(access: access, scanner: FolderBrowser())
    first.session.folderScan = scan
    try await scan.begin(folder: base, rootID: root).value
    let ids = try #require(scan.snapshot?.navigationEntries.map(\.itemID))
    #expect(ids.count == 2)
    first.session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids.first)
    first.session.select(ids[0])
    let main = try #require(NSApp.mainMenu)
    let view = try #require(main.items.first { $0.title == String(localized: "View") }?.submenu)
    let item = try #require(view.items.first { $0.accessibilityIdentifier() == "folder.loop.menu" })
    #expect(item.title == String(localized: "Loop Through Images"))
    #expect(item.keyEquivalent.isEmpty)
    let input = Issue344MenuInput()
    let intent = AccessIntent()
    await second.session.openInput(files, operation: intent.current,
        admission: ViewerInputAdmission(access: access, pipeline: ImageIOPipeline(), maximumPixelSize: 64,
            rootCovering: { _ in nil }), host: input)
    #expect(second.session.filePreviewSet != nil && !second.session.hasFolderSource)
    #expect(input.opened == [files[0]])

    func activate(_ controller: CanvasWindowController) throws {
        activeController = controller
        #expect(menu.activeWindowController === controller)
    }
    func expectChecked(_ controller: CanvasWindowController, value: Bool) throws {
        try activate(controller)
        #expect(menu.validateMenuItem(item))
        #expect(item.state == (value ? .on : .off))
        #expect(controller.session.displayPreferences.loopThroughImages == value)
    }
    func toggle(_ controller: CanvasWindowController, value: Bool) throws {
        try activate(controller)
        #expect(menu.validateMenuItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(store.value.loopThroughImages == value)
        try expectChecked(first, value: value)
        try expectChecked(second, value: value)
    }
    try expectChecked(first, value: false)
    try toggle(first, value: true)
    #expect(CommandRouter().route(.preview, from: .key, to: first.session))
    #expect(first.session.previewSet != nil)
    try toggle(first, value: false)
    try toggle(second, value: true)
    #expect(store.value.alwaysShowTools == false && store.value.folderSort == .name)
    second.session.endFilePreviewSet()
    try activate(second)
    #expect(!menu.validateMenuItem(item))
    #expect(item.state == .on, "A disabled loop item still reports the global saved value")
}
