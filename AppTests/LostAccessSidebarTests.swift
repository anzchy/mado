import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

private struct T232SidebarBookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}

private actor T232SidebarMounts: DiskMountPort {
    private var continuation: AsyncStream<DiskMountEvent>.Continuation?
    func mountedVolumes() -> [AccessProbeVolume] { [] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { continuation = $0 } }
}

private final class T232SidebarWatchSource: FolderEventSource, @unchecked Sendable {
    private struct Stream: FolderEventStream { func stop() {} }
    func start(watching url: URL, onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) throws -> any FolderEventStream {
        Stream()
    }
}

@MainActor private final class T232SidebarMotion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

private struct T232SidebarReadTotals: Equatable {
    let children: Int
    let counts: Int
}

private actor T232SidebarEnumerator: SidebarFolderEnumerating {
    private let childRows: [String: [URL]]
    private let imageCounts: [String: Int]
    private var childrenReads = 0
    private var countReads = 0
    init(childRows: [String: [URL]], imageCounts: [String: Int]) {
        self.childRows = childRows; self.imageCounts = imageCounts
    }
    func children(in folder: URL, root: URL) -> [URL] {
        childrenReads += 1
        return childRows[folder.standardizedFileURL.path] ?? []
    }
    func imageCount(in folder: URL, root: URL) -> Int {
        countReads += 1
        return imageCounts[folder.standardizedFileURL.path] ?? 0
    }
    var totals: T232SidebarReadTotals { T232SidebarReadTotals(children: childrenReads, counts: countReads) }
}

@MainActor private func t232SidebarWait(_ condition: @MainActor () -> Bool) async throws {
    while !condition() { await Task.yield() }
    #expect(condition())
}

@MainActor private func t232SidebarShell(_ controller: CanvasWindowController) throws -> GridShellView {
    try #require(controller.window?.contentView?.subviews.compactMap { $0 as? GridShellView }.first)
}

@MainActor private func t232SidebarLostPage(_ controller: CanvasWindowController) throws -> LostAccessStateView {
    try #require(try t232SidebarShell(controller).mainContent.subviews
        .compactMap { $0 as? LostAccessStateView }.first { !$0.isHiddenOrHasHiddenAncestor })
}

@MainActor private struct T232SidebarFixture {
    let base: URL
    let rootURL: URL
    let one: URL
    let two: URL
    let dayOne: URL
    let dayTwo: URL
    let rootID: AccessRootID
    let services: AccessServices
    let enumerator: T232SidebarEnumerator

    init() async throws {
        _ = NSApplication.shared
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        rootURL = base.appendingPathComponent("Root", isDirectory: true)
        one = rootURL.appendingPathComponent("One", isDirectory: true)
        two = rootURL.appendingPathComponent("Two", isDirectory: true)
        dayOne = one.appendingPathComponent("Day One", isDirectory: true)
        dayTwo = two.appendingPathComponent("Day Two", isDirectory: true)
        for folder in [dayOne, dayTwo] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        for folder in [one, two] {
            try FileManager.default.copyItem(at: image, to: folder.appendingPathComponent("image.png"))
        }
        let bookmarks = T232SidebarBookmarks()
        let files = try FileAccess(scope: bookmarks, bookmarks: bookmarks,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T232-sidebar")
        rootID = try await files.grant(folder: rootURL)
        services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: T232SidebarWatchSource(),
                scheduler: DispatchWatchScheduler()), mounts: T232SidebarMounts())
        enumerator = T232SidebarEnumerator(childRows: [one.path: [dayOne], two.path: [dayTwo]],
            imageCounts: [rootURL.path: 9, one.path: 1, two.path: 2, dayOne.path: 3, dayTwo.path: 4])
    }

    func controller() -> CanvasWindowController {
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: T232SidebarMotion()))
        controller.sidebarBrowserOverride = SidebarFolderBrowser(access: services.files, enumerator: enumerator)
        return controller
    }

    func ready(_ controller: CanvasWindowController, current: URL, day: URL, count: Int) async throws {
        let shell = try t232SidebarShell(controller)
        try await t232SidebarWait {
            controller.session.folderScan?.snapshot?.isComplete == true &&
            shell.folderTree.rows.map(\.folderURL) == [rootURL, current, day] &&
            shell.folderTree.rows.allSatisfy { !$0.countLabel.isHidden }
        }
        #expect(shell.folderTree.rows[0].countLabel.stringValue == "9")
        #expect(shell.folderTree.rows[1].countLabel.stringValue == String(count))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [
    AccessLossCause.diskNotConnected, .notFound, .accessExpired, .unknown,
])
func t232LostAccessSidebarAcrossCausesAgreesWithoutReads(_ cause: AccessLossCause) async throws {
    let fixture = try await T232SidebarFixture()
    defer { fixture.remove() }
    let controllers = [fixture.controller(), fixture.controller()]
    defer { for controller in controllers { controller.window?.close() } }
    controllers[0].browseRecoveredFolder(fixture.one, rootID: fixture.rootID)
    controllers[1].browseRecoveredFolder(fixture.two, rootID: fixture.rootID)
    try await fixture.ready(controllers[0], current: fixture.one, day: fixture.dayOne, count: 1)
    try await fixture.ready(controllers[1], current: fixture.two, day: fixture.dayTwo, count: 2)
    let readsBeforeLoss = await fixture.enumerator.totals
    await fixture.services.monitor.register(fixture.rootID)
    let lost = fixture.services.monitor.state.reportRootFailure(fixture.rootID, cause: cause,
        from: fixture.services.monitor.state.stamp(for: fixture.rootID))
    #expect(lost)
    try await t232SidebarWait { controllers.allSatisfy { $0.waitingAccessPosition?.rootID == fixture.rootID } }

    for (index, current) in [fixture.one, fixture.two].enumerated() {
        let controller = controllers[index]
        let shell = try t232SidebarShell(controller)
        #expect(controller.accessLossCause == cause)
        #expect(!shell.folderTree.isHidden)
        #expect(shell.folderTree.rows.map(\.folderURL) == [fixture.rootURL, current])
        #expect(shell.folderTree.children.isEmpty)
        #expect(shell.folderTree.guide.isHidden)
        let parentRow = try #require(shell.folderTree.rows.first { !$0.current })
        #expect(parentRow.accessLossCause == nil)
        let row = try #require(shell.folderTree.rows.first { $0.current })
        #expect(row.current && row.accessLossCause == cause)
        #expect(row.nameLabel.stringValue == current.lastPathComponent)
        #expect(row.countLabel.isHidden && !row.warningGlyph.isHidden && !row.disclosureGlyph.isHidden)
        _ = try t232SidebarLostPage(controller)
        row.performClick(nil)
        #expect(controller.waitingAccessPosition?.rootID == fixture.rootID)
        _ = try t232SidebarLostPage(controller)
    }
    #expect(await fixture.enumerator.totals == readsBeforeLoss)

    if cause == .accessExpired {
        let shell = try t232SidebarShell(controllers[0])
        let width = shell.mainFrame.minX
        controllers[0].toggleGridSidebar()
        shell.layoutSubtreeIfNeeded()
        #expect(shell.mainFrame.minX == 0)
        #expect(shell.folderTree.rows.count == 2)
        controllers[0].toggleGridSidebar()
        shell.layoutSubtreeIfNeeded()
        #expect(shell.mainFrame.minX == width)
    }
    #expect(await fixture.enumerator.totals == readsBeforeLoss)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [
    AccessLossCause.diskNotConnected, .notFound, .accessExpired, .unknown,
])
func t232RecoveryRestoresNormalTreesAndCountsAcrossCauses(_ cause: AccessLossCause) async throws {
    let fixture = try await T232SidebarFixture()
    defer { fixture.remove() }
    let controllers = [fixture.controller(), fixture.controller()]
    defer { for controller in controllers { controller.window?.close() } }
    controllers[0].browseRecoveredFolder(fixture.one, rootID: fixture.rootID)
    controllers[1].browseRecoveredFolder(fixture.two, rootID: fixture.rootID)
    try await fixture.ready(controllers[0], current: fixture.one, day: fixture.dayOne, count: 1)
    try await fixture.ready(controllers[1], current: fixture.two, day: fixture.dayTwo, count: 2)
    await fixture.services.monitor.register(fixture.rootID)
    _ = fixture.services.monitor.state.reportRootFailure(fixture.rootID, cause: cause,
        from: fixture.services.monitor.state.stamp(for: fixture.rootID))
    try await t232SidebarWait {
        controllers.allSatisfy { $0.waitingAccessPosition?.rootID == fixture.rootID && $0.accessLossCause == cause }
    }

    await fixture.services.monitor.reauthorize(fixture.rootID)
    for (index, current) in [fixture.one, fixture.two].enumerated() {
        let day = index == 0 ? fixture.dayOne : fixture.dayTwo
        let expectedCount = index == 0 ? 1 : 2
        let controller = controllers[index]
        let shell = try t232SidebarShell(controller)
        try await t232SidebarWait {
            controller.waitingAccessPosition == nil && controller.session.folderScan?.snapshot?.isComplete == true &&
            shell.folderTree.rows.map(\.folderURL) == [fixture.rootURL, current, day] &&
            shell.folderTree.rows.allSatisfy { !$0.countLabel.isHidden }
        }
        #expect(controller.accessLossCause == nil)
        #expect(shell.folderTree.rows[0].countLabel.stringValue == "9")
        let row = shell.folderTree.rows[1]
        #expect(row.accessLossCause == nil)
        #expect(row.countLabel.stringValue == String(expectedCount))
        #expect(row.warningGlyph.isHidden && row.disclosureGlyph.isHidden)
        #expect(shell.folderTree.rows[2].countLabel.stringValue == (index == 0 ? "3" : "4"))
        #expect(shell.mainContent.subviews.compactMap { $0 as? LostAccessStateView }.allSatisfy { $0.isHidden })
    }
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t232LostSidebarRefinementKeepsEveryWindowCauseCurrentWithoutReads() async throws {
    let fixture = try await T232SidebarFixture()
    defer { fixture.remove() }
    var controllers = [fixture.controller(), fixture.controller()]
    defer { for controller in controllers { controller.window?.close() } }
    controllers[0].browseRecoveredFolder(fixture.one, rootID: fixture.rootID)
    controllers[1].browseRecoveredFolder(fixture.two, rootID: fixture.rootID)
    try await fixture.ready(controllers[0], current: fixture.one, day: fixture.dayOne, count: 1)
    try await fixture.ready(controllers[1], current: fixture.two, day: fixture.dayTwo, count: 2)
    let readsBeforeLoss = await fixture.enumerator.totals
    let state = fixture.services.monitor.state
    state.register(fixture.rootID, volumeUUID: "T232-refinement")
    _ = state.reportRootFailure(fixture.rootID, cause: .diskNotConnected,
        from: state.stamp(for: fixture.rootID))
    try await t232SidebarWait { controllers.allSatisfy { $0.accessLossCause == .diskNotConnected } }
    let attempt = try #require(state.diskMounted(volumeUUID: "T232-refinement").first)

    func expectCause(_ cause: AccessLossCause, _ title: String) throws {
        for controller in controllers {
            let shell = try t232SidebarShell(controller)
            let row = try #require(shell.folderTree.rows.first { $0.current })
            let expected = "\(String(localized: "Unavailable")), \(String(localized: String.LocalizationValue(title)))"
            #expect(controller.accessLossCause == cause)
            #expect(row.accessLossCause == cause)
            #expect(row.accessibilityValue() as? String == expected)
            #expect(row.accessibilityHelp() == expected)
            #expect(try t232SidebarLostPage(controller).titleLabel.stringValue == String(format:
                String(localized: String.LocalizationValue(cause == .notFound ? "Can’t Find “%@”" : "Unable to Access “%@”")),
                try #require(controller.waitingAccessPosition).folderURL.lastPathComponent))
        }
    }

    #expect(state.refineRecoveryFailure(attempt, cause: .notFound))
    try await t232SidebarWait { controllers.allSatisfy { $0.accessLossCause == .notFound } }
    let lateController = fixture.controller()
    controllers.append(lateController)
    lateController.browseRecoveredFolder(fixture.one, rootID: fixture.rootID)
    try await t232SidebarWait { lateController.accessLossCause == .notFound }
    try expectCause(.notFound, "Not Found")
    #expect(await fixture.enumerator.totals == readsBeforeLoss)

    #expect(state.refineRecoveryFailure(attempt, cause: .accessExpired))
    try await t232SidebarWait { controllers.allSatisfy { $0.accessLossCause == .accessExpired } }
    try expectCause(.accessExpired, "Access Has Expired")
    #expect(await fixture.enumerator.totals == readsBeforeLoss)
}
