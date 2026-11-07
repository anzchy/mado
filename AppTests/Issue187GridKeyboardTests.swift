import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue187MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue187Grid(in view: NSView?) -> GridBrowserView? {
    guard let view else { return nil }
    if let grid = view as? GridBrowserView { return grid }
    for subview in view.subviews { if let grid = issue187Grid(in: subview) { return grid } }
    return nil
}

@MainActor private func issue187Down(_ window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
        charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)
}

/// #187 AC-2: after the Reading State hands over to the grid, keyboard focus is on the grid without a click,
/// on both folder-open paths, with the window shown and its updates (state host refresh) running through reading.
@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func issue187OpenedGridTakesKeyboardFocusAndFirstDownMovesOneRow(granted: Bool) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = base.appendingPathComponent("photos")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    for index in 1...120 { try data.write(to: folder.appendingPathComponent(String(format: "%03d.png", index))) }

    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue187")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue187MotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    controller.showWindow(nil)
    window.orderFrontRegardless()
    window.update()
    if granted { controller.openGrantedFolder(folder) }
    else {
        controller.browseRecoveredFolder(folder, rootID: try await access.grant(folder: folder))
        // The handover under test: Reading State shows with Cancel focused before the grid exists.
        #expect(!controller.gridSearchAvailable)
        #expect(window.firstResponder is NSButton)
    }
    try await waitUntil {
        if controller.gridSearchAvailable { return true }
        window.update()
        return false
    }
    #expect(controller.gridSearchAvailable)
    let grid = try #require(issue187Grid(in: window.contentView))
    // Focus is on the grid from the first check after the handover and stays there through later
    // Reading State teardown and state host refreshes (no deferred focus fix-up).
    for poll in 0..<20 {
        #expect(window.firstResponder === grid.collectionView, "poll \(poll): \(String(describing: window.firstResponder))")
        window.update()
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(grid.displayedItemIDs.count == 120)
    #expect(grid.currentItemID == grid.itemID(at: 0))

    window.layoutIfNeeded()
    let firstRow = grid.collectionView.frameForItem(at: 0).minY
    let columns = (0..<120).prefix { grid.collectionView.frameForItem(at: $0).minY == firstRow }.count
    #expect(columns > 1)
    window.sendEvent(try #require(issue187Down(window)))
    #expect(grid.currentItemID == grid.itemID(at: columns))
    window.sendEvent(try #require(issue187Down(window)))
    #expect(grid.currentItemID == grid.itemID(at: 2 * columns))
}
