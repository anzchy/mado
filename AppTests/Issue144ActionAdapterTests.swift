import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue144Motion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}
@MainActor private final class Issue144Copier: PathCopying {
    var calls: [[URL]] = []
    func copyPaths(_ urls: [URL]) { calls.append(urls) }
}
@MainActor private final class Issue144Revealer: FileRevealing {
    var calls: [[URL]] = []
    func reveal(_ urls: [URL]) { calls.append(urls) }
}
@MainActor private func issue144Grid(_ view: NSView?) -> GridBrowserView? {
    guard let view else { return nil }
    if let grid = view as? GridBrowserView { return grid }
    return view.subviews.lazy.compactMap { issue144Grid($0) }.first
}

@Test @MainActor func issue144CopyPathReplacesPasteboardWithOneStoredPathPerLine() throws {
    let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("old content", forType: .string)
    let copier = PasteboardPathCopier(pasteboard: pasteboard)
    let urls = [URL(fileURLWithPath: "/tmp/Mado first.png"), URL(fileURLWithPath: "/tmp/第二张.png")]
    copier.copyPaths(urls)
    #expect(pasteboard.string(forType: .string) == "/tmp/Mado first.png\n/tmp/第二张.png")
    #expect(pasteboard.pasteboardItems?.count == 1)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue144MenuCopyUsesCapturedUnselectedTargetAfterCurrentChanges() async throws {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("issue144-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("Images")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: fixture)
    for i in 0..<6 { try data.write(to: folder.appendingPathComponent(String(format: "%03d.png", i))) }
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue144")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Issue144Motion()))
    let window = try #require(controller.window)
    defer { window.close() }
    let copier = Issue144Copier()
    let revealer = Issue144Revealer()
    controller.pathCopier = copier
    controller.fileRevealer = revealer
    controller.openGrantedFolder(folder)
    try await waitUntil("grid ready", between: { window.contentView?.layoutSubtreeIfNeeded() }) {
        controller.gridSearchAvailable && (issue144Grid(window.contentView)?.displayedItemIDs.count ?? 0) == 6
    }
    let grid = try #require(issue144Grid(window.contentView))
    let ids = grid.displayedItemIDs
    controller.session.select(ids[0])
    let menu = try #require(controller.makeGridImageContextMenu(for: ids[3]))
    controller.session.focus(ids[5])
    controller.session.select(ids[2])
    let item = menu.items[3]
    #expect(item.isEnabled)
    menu.delegate?.menuWillOpen?(menu)
    menu.delegate?.menuDidClose?(menu)
    #expect(!controller.session.isMenuTracking)
    let closedMenuTarget = try #require(item.target)
    _ = NSApp.sendAction(try #require(item.action), to: closedMenuTarget, from: item)
    try await waitUntil("copy delivered") { !copier.calls.isEmpty }
    #expect(copier.calls == [[try #require(grid.entry(for: ids[3])).url]])

    window.appearance = NSAppearance(named: .darkAqua)
    let darkMenu = try #require(controller.makeGridImageContextMenu(for: ids[3]))
    #expect(darkMenu.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    window.appearance = NSAppearance(named: .aqua)
    let lightMenu = try #require(controller.makeGridImageContextMenu(for: ids[3]))
    #expect(lightMenu.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    lightMenu.delegate?.menuWillOpen?(lightMenu)
    #expect(controller.session.isMenuTracking)
    lightMenu.delegate?.menuDidClose?(lightMenu)
    #expect(!controller.session.isMenuTracking)
    #expect(window.firstResponder === grid.collectionView)
    let infoMenu = try #require(controller.makeGridImageContextMenu(for: ids[3]))
    let infoItem = infoMenu.items[4]
    _ = NSApp.sendAction(try #require(infoItem.action), to: infoItem.target, from: infoItem)
    #expect(controller.session.selection.currentItemID == ids[3])
    #expect(controller.session.inspectorFocus.isVisible)

    controller.session.select(ids[1])
    controller.session.select(ids[2], modifier: .command)
    controller.session.select(ids[4], modifier: .command)
    let multiMenu = try #require(controller.makeGridImageContextMenu(for: ids[2]))
    controller.session.select(ids[0])
    let revealItem = multiMenu.items[2]
    _ = NSApp.sendAction(try #require(revealItem.action), to: revealItem.target, from: revealItem)
    try await waitUntil("reveal delivered") { revealer.calls.count == 1 }
    #expect(revealer.calls[0] == [ids[1], ids[2], ids[4]].compactMap { grid.entry(for: $0)?.url })

    controller.session.select(ids[1])
    controller.session.select(ids[2], modifier: .command)
    controller.session.select(ids[4], modifier: .command)
    let partialMenu = try #require(controller.makeGridImageContextMenu(for: ids[2]))
    try FileManager.default.removeItem(at: try #require(grid.entry(for: ids[2])).url)
    partialMenu.update()
    #expect(partialMenu.items[2].isEnabled)
    let partialItem = partialMenu.items[2]
    _ = NSApp.sendAction(try #require(partialItem.action), to: partialItem.target, from: partialItem)
    try await waitUntil("partial reveal delivered") { revealer.calls.count == 2 }
    #expect(revealer.calls[1] == [ids[1], ids[4]].compactMap { grid.entry(for: $0)?.url })

    let unavailableMenu = try #require(controller.makeGridImageContextMenu(for: ids[3]))
    try FileManager.default.removeItem(at: try #require(grid.entry(for: ids[3])).url)
    grid.clearPresentation()
    #expect(unavailableMenu.items[2].isEnabled == false)
    #expect(unavailableMenu.items[3].isEnabled == false)
    let staleItem = unavailableMenu.items[3]
    _ = NSApp.sendAction(try #require(staleItem.action), to: staleItem.target, from: staleItem)
    #expect(copier.calls.count == 1)
}
