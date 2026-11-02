import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure
import PicseeMacUI

private final class RecoveryBookmarks: SecurityScope, BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Data: FileResourceIdentity] = [:]
    private var locations: [Data: URL] = [:]
    private var failures: Set<String> = []
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data {
        let identity = try URLIdentityResourceReader().identity(for: url)
        // A bookmark is an object-specific token. A new directory at the old
        // spelling must not inherit the prior token's moved location/identity.
        let token = Data("\(UUID().uuidString)|\(url.path)".utf8)
        lock.withLock { identities[token] = identity; locations[token] = url }
        return token
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        try lock.withLock {
            guard let url = locations[data], !failures.contains(url.path) else {
                throw NSError(domain: "T229RecoveryResolution", code: 1)
            }
            return ResolvedBookmark(url: url, stale: false)
        }
    }
    func identity(_ data: Data) -> FileResourceIdentity? { lock.withLock { identities[data] } }
    func relocate(_ old: URL, to new: URL) {
        lock.withLock {
            for (token, url) in locations where url.standardizedFileURL == old.standardizedFileURL {
                locations[token] = new
            }
        }
    }
    func fail(_ root: URL, _ failed: Bool) {
        lock.withLock { if failed { _ = failures.insert(root.path) } else { _ = failures.remove(root.path) } }
    }
}

private actor RecoveryMounts: DiskMountPort {
    private var volumes = [AccessProbeVolume(uuid: "111", url: nil, name: "Disk"), AccessProbeVolume(uuid: "222", url: nil, name: "Other")]
    private var continuation: AsyncStream<DiskMountEvent>.Continuation?
    private var pauseNext = false
    private var enumerationsBeforePause = 0
    private var pauseObservers: [AsyncStream<Void>.Continuation] = []
    private var waiting: [(CheckedContinuation<[AccessProbeVolume], Never>, [AccessProbeVolume])] = []
    private(set) var paused = false
    func mountedVolumes() async -> [AccessProbeVolume] {
        // Capture before suspension: a late success must still lose to a newer eject.
        let captured = volumes
        if pauseNext {
            if enumerationsBeforePause > 0 {
                enumerationsBeforePause -= 1
                return captured
            }
            pauseNext = false; paused = true
            let observers = pauseObservers; pauseObservers = []
            for observer in observers { observer.finish() }
            return await withCheckedContinuation { waiting.append(($0, captured)) }
        }
        return captured
    }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { continuation = $0 } }
    func emit(_ event: DiskMountEvent) {
        switch event {
        case .mounted(let volume): volumes.removeAll { $0.uuid == volume.uuid }; volumes.append(volume)
        case .unmounted(let volume): volumes.removeAll { $0.uuid == volume.uuid }
        }
        continuation?.yield(event)
    }
    func pauseEnumeration(after enumerations: Int = 0) {
        pauseNext = true; paused = false; enumerationsBeforePause = enumerations
    }
    func waitUntilPaused() async throws {
        try Task.checkCancellation()
        if paused { return }
        let (stream, observer) = AsyncStream<Void>.makeStream()
        pauseObservers.append(observer)
        for await _ in stream { }
        try Task.checkCancellation()
        guard paused else { throw CancellationError() }
    }
    func release() {
        pauseNext = false; paused = false; enumerationsBeforePause = 0
        let observers = pauseObservers; pauseObservers = []
        for observer in observers { observer.finish() }
        let held = waiting; waiting = []
        for (continuation, captured) in held { continuation.resume(returning: captured) }
    }
}

/// Gates only the real enumerator's resource-values I/O; neither App state nor scan results are fabricated.
private final class RecoveryReadGate: FileIdentityResourceReading, @unchecked Sendable {
    private let condition = NSCondition()
    private var prefix: String?
    private var blocked = false
    private var mountGeneration = 0
    func nextMount() { condition.lock(); mountGeneration += 1; condition.unlock() }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        let raw = try URLIdentityResourceReader().identity(for: fileURL)
        condition.lock(); let generation = mountGeneration; condition.unlock()
        return raw.map { FileResourceIdentity(volumeUUID: $0.volumeUUID,
            fileIdentifier: generation == 0 ? $0.fileIdentifier : "dev\(generation):\($0.fileIdentifier)") }
    }
    var isBlocked: Bool { condition.lock(); defer { condition.unlock() }; return blocked }
    func arm(_ folder: URL) { condition.lock(); prefix = folder.path + "/"; blocked = false; condition.unlock() }
    func release() { condition.lock(); prefix = nil; blocked = false; condition.broadcast(); condition.unlock() }
    func read(_ url: URL) throws -> URLResourceValues {
        condition.lock()
        if let prefix, url.path.hasPrefix(prefix) {
            blocked = true
            // The test releases this gate explicitly, including in deferred cleanup.
            // CI scheduling delay must not release the held scan early.
            while blocked { condition.wait() }
            blocked = false
        }
        condition.unlock()
        return try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .contentTypeKey,
            .contentModificationDateKey, .fileSizeKey, .volumeUUIDStringKey, .fileIdentifierKey])
    }
}

private final class RecoveryWatchSource: FolderEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [UUID: URL] = [:]
    private var hints: [UUID: @Sendable ([FolderChangeHint]) -> Void] = [:]
    var activeURLs: [URL] { lock.withLock { Array(live.values) } }
    private final class Stream: FolderEventStream, @unchecked Sendable {
        let stopAction: @Sendable () -> Void
        init(_ stop: @escaping @Sendable () -> Void) { stopAction = stop }
        func stop() { stopAction() }
    }
    func start(watching url: URL, onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) throws -> any FolderEventStream {
        let id = UUID()
        lock.withLock { live[id] = url }
        lock.withLock { hints[id] = onHints }
        return Stream { [self] in _ = lock.withLock { live.removeValue(forKey: id) } }
    }
    func emit(_ hint: FolderChangeHint, root: URL) {
        let callbacks = lock.withLock { live.filter { $0.value == root }.keys.compactMap { hints[$0] } }
        for callback in callbacks { callback([hint]) }
    }
}

extension FileAccess {
    /// Runs `body` as one turn of the actor, so no lease can resolve a root between its steps.
    fileprivate func runIsolated(_ body: @Sendable () throws -> Void) throws { try body() }
}

@MainActor private final class RecoveryMotion: ReduceMotionSource {
    var reduceMotion = true
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func recoveryWait(_ predicate: @MainActor () -> Bool) async throws {
    while !predicate() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(predicate())
}
@MainActor private func recoveryWaitAsync(_ predicate: @MainActor () async -> Bool) async throws {
    while !(await predicate()) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await predicate())
}
@MainActor private func recoveryShell(_ controller: CanvasWindowController) throws -> GridShellView {
    try #require(controller.window?.contentView?.subviews.compactMap { $0 as? GridShellView }.first)
}
@MainActor private func recoveryGrid(_ controller: CanvasWindowController) throws -> GridBrowserView {
    try #require(try recoveryShell(controller).mainContent.subviews.compactMap { $0 as? GridBrowserView }.first)
}
@MainActor private func recoveryPage(_ controller: CanvasWindowController) -> LostAccessStateView? {
    controller.window?.contentView?.subviews.compactMap { $0 as? GridShellView }.first?
        .mainContent.subviews.compactMap { $0 as? LostAccessStateView }.first { !$0.isHiddenOrHasHiddenAncestor }
}

@MainActor private struct RecoveryFixture {
    let base: URL
    let a: URL
    let b: URL
    let childOne: URL
    let childTwo: URL
    let rootA: AccessRootID
    let rootB: AccessRootID
    let bookmarks: RecoveryBookmarks
    let mounts: RecoveryMounts
    let gate: RecoveryReadGate
    let watchSource: RecoveryWatchSource
    let services: AccessServices
    init(diagnostics: AccessDiagnostics = AccessDiagnostics(), aComponents: [String] = ["RootA"]) async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let a = aComponents.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }, b = base.appendingPathComponent("RootB", isDirectory: true)
        let one = a.appendingPathComponent("One", isDirectory: true), two = a.appendingPathComponent("Two", isDirectory: true)
        for folder in [one, two, b] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        for folder in [one, two] {
            try fm.copyItem(at: fixture, to: folder.appendingPathComponent("one.png"))
            try fm.copyItem(at: fixture, to: folder.appendingPathComponent("two.jpg"))
        }
        try fm.copyItem(at: fixture, to: a.appendingPathComponent("root.png"))
        try fm.copyItem(at: fixture, to: b.appendingPathComponent("other.png"))
        let bookmarks = RecoveryBookmarks()
        let files = try FileAccess(scope: bookmarks, bookmarks: bookmarks,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-recovery",
            diagnostics: diagnostics,
            bookmarkVolume: { data in AccessProbeVolume(uuid: String(decoding: data, as: UTF8.self).hasSuffix("RootB") ? "222" : "111", url: nil, name: "Disk") },
            resolvedVolumeUUID: { url in url.path.contains("RootB") ? "222" : "111" },
            bookmarkIdentity: { bookmarks.identity($0) })
        let rootA = try await files.grant(folder: a), rootB = try await files.grant(folder: b)
        let mounts = RecoveryMounts(), gate = RecoveryReadGate(), source = RecoveryWatchSource()
        self.base = base; self.a = a; self.b = b; childOne = one; childTwo = two
        self.rootA = rootA; self.rootB = rootB; self.bookmarks = bookmarks; self.mounts = mounts; self.gate = gate; watchSource = source
        services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(readValues: { try gate.read($0) }, resourceReader: gate),
            watch: WatchHub(access: files, source: source, scheduler: DispatchWatchScheduler()), mounts: mounts, selectionScope: bookmarks)
    }
    func controller() -> CanvasWindowController {
        CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: RecoveryMotion()))
    }
    func eject() async { await mounts.emit(.unmounted(AccessProbeVolume(uuid: "111", url: nil, name: "Disk"))) }
    func mount() async { await mounts.emit(.mounted(AccessProbeVolume(uuid: "111", url: nil, name: "Disk"))) }
    func ready(_ controller: CanvasWindowController, folder: URL, count: Int? = nil) async throws {
        let grid = try recoveryGrid(controller)
        try await recoveryWait {
            controller.session.folderScan?.snapshot?.isComplete == true &&
            controller.session.folderScan?.snapshot?.version.folder == folder && !grid.isHiddenOrHasHiddenAncestor &&
            (count.map { grid.displayedItemIDs.count == $0 } ?? !grid.displayedItemIDs.isEmpty)
        }
    }
    /// A real bookmark resolves to the moved folder at once. Moving the folder and relocating the fake bookmark
    /// in one FileAccess turn keeps a lease (a thumbnail or metadata read still in flight) from resolving the
    /// old path after it is gone, which drops the root as needing reconnection (#290).
    func moveRoot(to destination: URL) async throws {
        let source = a, bookmarks = bookmarks
        try await services.files.runIsolated {
            try FileManager.default.moveItem(at: source, to: destination)
            bookmarks.relocate(source, to: destination)
        }
    }
    func remove() { gate.release(); try? FileManager.default.removeItem(at: base) }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229RecoveryRestoresTwoIndependentPositionsAfterRootMoves() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let viewer = f.controller(), gridWindow = f.controller()
    defer { viewer.window?.close(); gridWindow.window?.close() }
    viewer.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    gridWindow.browseRecoveredFolder(f.childTwo, rootID: f.rootA)
    try await f.ready(viewer, folder: f.childOne, count: 2)
    try await f.ready(gridWindow, folder: f.childTwo, count: 2)
    let viewerConditions = FolderViewConditions(sort: .name, direction: .descending, selectedExtensions: ["png"])
    let gridConditions = FolderViewConditions(sort: .size, direction: .ascending, selectedExtensions: ["jpg"])
    viewer.session.setFolderConditions(viewerConditions)
    gridWindow.session.setFolderConditions(gridConditions)
    try await f.ready(viewer, folder: f.childOne, count: 1)
    try await f.ready(gridWindow, folder: f.childTwo, count: 1)
    let image = try #require(viewer.session.folderScan?.snapshot?.navigationEntries.first)
    let selected = try #require(gridWindow.session.folderScan?.snapshot?.navigationEntries.first)
    gridWindow.session.focus(selected.itemID)
    viewer.session.focus(image.itemID)
    #expect(viewer.route(.enter, from: .key))
    try await recoveryWait { viewer.session.mode == .viewing && viewer.hasImage && viewer.session.imageLoader.presented != nil }
    var announcements: [String] = []
    viewer.accessAnnouncementObserver = { announcements.append($0) }
    gridWindow.accessAnnouncementObserver = { announcements.append($0) }
    await f.eject()
    try await recoveryWait { recoveryPage(viewer) != nil && recoveryPage(gridWindow) != nil }
    try await recoveryWait { announcements.count == 1 }
    let moved = f.base.appendingPathComponent("RemountedRoot", isDirectory: true)
    try await f.moveRoot(to: moved)
    await f.mount()
    let movedImage = moved.appendingPathComponent("One/one.png")
    do {
    // FolderBrowser keeps the enumerator's physical /private/var spelling (pinned by ExternalCurrentFileTests).
    let movedImage = URL(fileURLWithPath: movedImage.path.hasPrefix("/var/") ? "/private" + movedImage.path : movedImage.path)
    try await recoveryWait { viewer.waitingAccessPosition == nil && viewer.hasImage && viewer.session.imageLoader.fileURL == movedImage }
    try await f.ready(gridWindow, folder: moved.appendingPathComponent("Two"), count: 1)
    #expect(viewer.session.mode == .viewing && gridWindow.session.mode == .browsing)
    #expect(viewer.session.folderConditions == viewerConditions)
    #expect(gridWindow.session.folderConditions == gridConditions)
    #expect(gridWindow.session.selection.currentItemID == selected.itemID)
    #expect(viewer.window?.representedURL == movedImage)
    #expect(gridWindow.window?.representedURL == moved.appendingPathComponent("Two"))
    #expect(f.watchSource.activeURLs.contains(moved))
    try await recoveryWait { announcements.count == 2 }
    #expect(announcements.count == 2)
    let later = moved.appendingPathComponent("Two/later.jpg")
    try FileManager.default.copyItem(at: movedImage, to: later)
    f.watchSource.emit(.changed(later), root: moved)
    try await f.ready(gridWindow, folder: moved.appendingPathComponent("Two"), count: 2)
    #expect(gridWindow.session.selection.currentItemID == selected.itemID)
    }
}

private enum RecoveryMissing: String, CaseIterable, Sendable { case childGone, itemGone, childReplaced, itemReplaced }
@MainActor @Test(.timeLimit(.minutes(3)), arguments: RecoveryMissing.allCases)
private func t229RecoveryFallsBackToRootGridWhenOriginalPositionIsGone(_ missing: RecoveryMissing) async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close() }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne, count: 2)
    let image = try #require(controller.session.folderScan?.snapshot?.entries.first { $0.url.lastPathComponent == "one.png" })
    controller.session.focus(image.itemID)
    #expect(controller.route(.enter, from: .key))
    try await recoveryWait { controller.session.mode == .viewing && controller.hasImage }
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    let fm = FileManager.default
    switch missing {
    case .childGone: try fm.removeItem(at: f.childOne)
    case .itemGone: try fm.removeItem(at: image.url)
    case .childReplaced:
        try fm.moveItem(at: f.childOne, to: f.base.appendingPathComponent("original-child"))
        try fm.createDirectory(at: f.childOne, withIntermediateDirectories: true)
        try fm.copyItem(at: f.childTwo.appendingPathComponent("one.png"), to: image.url)
    case .itemReplaced:
        try fm.moveItem(at: image.url, to: f.base.appendingPathComponent("original-image.png"))
        try fm.copyItem(at: f.childTwo.appendingPathComponent("one.png"), to: image.url)
    }
    await f.mount()
    try await f.ready(controller, folder: f.a, count: 1)
    #expect(controller.waitingAccessPosition == nil && recoveryPage(controller) == nil)
    #expect(controller.session.mode == .browsing && !controller.hasImage)
    #expect(controller.session.imageLoader.presented == nil)
    #expect(controller.window?.representedURL == f.a)
    #expect(controller.session.folderScan?.snapshot?.entries.first?.url.lastPathComponent == "root.png")
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229RecoveryFailedRootVerificationStaysUnknownThenRetriesSavedBookmark() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close() }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne)
    let saved = try #require(await f.services.files.records().first { $0.id == f.rootA }).bookmark
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    f.bookmarks.fail(f.a, true)
    await f.mount()
    // #231: mounted-volume bookmark failure is now the proven Not Found cause.
    try await recoveryWait { controller.accessLossCause != .diskNotConnected }
    #expect(controller.accessLossCause == .notFound)
    #expect(f.services.monitor.state.permit(for: f.rootA) == nil)
    #expect(!controller.hasImage && controller.session.imageLoader.presented == nil)
    #expect(recoveryPage(controller)?.buttons.count == 2)
    #expect(try recoveryGrid(controller).displayedItemIDs.isEmpty)
    f.bookmarks.fail(f.a, false)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try await f.ready(controller, folder: f.childOne, count: 2)
    #expect(controller.waitingAccessPosition == nil)
    #expect(await f.services.files.records().first { $0.id == f.rootA }?.bookmark == saved)
}

private struct RecoveryInterleaving: Sendable {
    let duringScan: Bool
    let secondEject: Bool
    static let all = [false, true].flatMap { duringScan in [false, true].map { Self(duringScan: duringScan, secondEject: $0) } }
}
@MainActor @Test(.timeLimit(.minutes(3)), arguments: RecoveryInterleaving.all)
private func t229RecoveryGeneratedNavigationAndSecondEjectInterleavings(_ trace: RecoveryInterleaving) async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let first = f.controller(), second = f.controller()
    try await withAsyncTeardown {
        first.browseRecoveredFolder(f.childOne, rootID: f.rootA)
        second.browseRecoveredFolder(f.childTwo, rootID: f.rootA)
        try await f.ready(first, folder: f.childOne)
        try await f.ready(second, folder: f.childTwo)
        await f.eject()
        try await recoveryWait { recoveryPage(first) != nil && recoveryPage(second) != nil }
        let lostCounter = try #require(f.services.monitor.state.snapshot(for: f.rootA)?.counter)
        if trace.duringScan { f.gate.arm(f.a) } else { await f.mounts.pauseEnumeration() }
        await f.mount()
        if trace.duringScan { try await recoveryWait { f.gate.isBlocked } }
        else { try await recoveryWaitAsync { await f.mounts.paused } }
        #expect(recoveryPage(first) != nil && recoveryPage(second) != nil)
        #expect(!first.hasImage && !second.hasImage)
        #expect(try recoveryGrid(first).displayedItemIDs.isEmpty)
        #expect(try recoveryGrid(second).displayedItemIDs.isEmpty)
        if trace.duringScan { #expect(f.watchSource.activeURLs.contains(f.a)) }
        first.browseRecoveredFolder(f.b, rootID: f.rootB)
        if trace.secondEject {
            await f.eject()
            try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.counter == lostCounter + 1 }
        }
        f.gate.release()
        await f.mounts.release()
        try await f.ready(first, folder: f.b, count: 1)
        #expect(first.waitingAccessPosition == nil && first.window?.representedURL == f.b)
        if trace.secondEject {
            #expect(recoveryPage(second) != nil)
            #expect(!second.hasImage && second.window?.representedURL == nil)
            await f.mount()
        }
        try await f.ready(second, folder: f.childTwo, count: 2)
        #expect(second.waitingAccessPosition == nil)
        #expect(second.session.folderScan?.snapshot?.version.rootID == f.rootA)
        #expect(first.session.folderScan?.snapshot?.version.rootID == f.rootB)
        #expect(first.window?.representedURL == f.b)
    } teardown: {
        first.window?.close(); second.window?.close(); f.gate.release(); await f.mounts.release()
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229RecoveryCancelReadingAnotherRootRestoresWaitingPosition() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close(); f.gate.release() }
    var announcements: [String] = []
    controller.accessAnnouncementObserver = { announcements.append($0) }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne)
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    let loss = try #require(announcements.first)
    let position = try #require(controller.waitingAccessPosition)
    f.gate.arm(f.b)
    controller.browseRecoveredFolder(f.b, rootID: f.rootB)
    let state = try #require(controller.window?.contentView?.subviews.compactMap { $0 as? ViewerStateHost }.first)
    let cancel = try #require(state.buttons.first)
    cancel.performClick(nil)
    #expect(controller.waitingAccessPosition?.rootID == position.rootID)
    #expect(controller.waitingAccessPosition?.folderURL == position.folderURL)
    #expect(controller.waitingAccessPosition?.counter == position.counter)
    #expect(recoveryPage(controller) != nil && controller.window?.representedURL == nil)
    #expect(!controller.hasImage)
    f.gate.release()
    await f.mount()
    try await f.ready(controller, folder: f.childOne, count: 2)
    #expect(announcements == [loss, "Folder Access Restored"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229RecoveryAnnouncementBudgetRestartsAfterNavigationAway() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close() }
    var announcements: [String] = []
    controller.accessAnnouncementObserver = { announcements.append($0) }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne)
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil && announcements.count == 1 }
    controller.browseRecoveredFolder(f.b, rootID: f.rootB)
    try await f.ready(controller, folder: f.b, count: 1)
    await f.mount()
    try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable }
    #expect(announcements.count == 1)
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne)
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil && announcements.count == 2 }
    await f.eject()
    #expect(announcements.count == 2)
    await f.mount()
    try await f.ready(controller, folder: f.childOne)
    try await recoveryWait { announcements.count == 3 }
    #expect(announcements.count == 3)
}

// Audit M6: the root is readable again, but one window's own folder cannot be
// listed. That window falls back to the root grid instead of staying on page 26,
// and loss is not announced again after "Folder Access Restored".
@MainActor @Test(.timeLimit(.minutes(3))) func t229FixPerWindowRestoreFailureFallsBackToRootGridWithoutReannouncingLoss() async throws {
    let f = try await RecoveryFixture()
    let viewer = f.controller(), gridWindow = f.controller()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.childTwo.path)
        viewer.window?.close(); gridWindow.window?.close(); f.remove()
    }
    viewer.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    gridWindow.browseRecoveredFolder(f.childTwo, rootID: f.rootA)
    try await f.ready(viewer, folder: f.childOne, count: 2)
    try await f.ready(gridWindow, folder: f.childTwo, count: 2)
    var announcements: [String] = []
    viewer.accessAnnouncementObserver = { announcements.append($0) }
    gridWindow.accessAnnouncementObserver = { announcements.append($0) }
    await f.eject()
    try await recoveryWait { recoveryPage(viewer) != nil && recoveryPage(gridWindow) != nil && announcements.count == 1 }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.childTwo.path)
    await f.mount()
    try await f.ready(viewer, folder: f.childOne, count: 2)
    try await recoveryWait { gridWindow.waitingAccessPosition == nil && recoveryPage(gridWindow) == nil }
    try await f.ready(gridWindow, folder: f.a)
    #expect(gridWindow.window?.representedURL == f.a)
    #expect(gridWindow.session.folderScan?.snapshot?.version.rootID == f.rootA)
    #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable)
    try await recoveryWait { announcements.count == 2 }
    // Recovery has announced; observe only unwanted repeat announcements.
    try await Task.sleep(for: .milliseconds(300))
    #expect(announcements.count == 2)
    #expect(announcements.filter { $0 == announcements.first }.count == 1)
}

// Audit gpt F1 (round 2): the recovery identity follows the grid the window
// shows. (a) The root moves while readable; a later eject and remount restore
// the moved child and its Current Item, not the root grid.
@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix2RecoveryFollowsRootMovedWhileReadable() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close() }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne, count: 2)
    let selected = try #require(controller.session.folderScan?.snapshot?.navigationEntries.last)
    controller.session.focus(selected.itemID)
    let moved = f.base.appendingPathComponent("MovedRoot", isDirectory: true)
    let movedChild = moved.appendingPathComponent("One", isDirectory: true)
    try await f.moveRoot(to: moved)
    for watched in [f.a, f.childOne] { f.watchSource.emit(.mustRescan, root: watched) }
    try await f.ready(controller, folder: movedChild, count: 2)
    try await recoveryWait { controller.window?.representedURL == movedChild }
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    await f.mount()
    try await f.ready(controller, folder: movedChild, count: 2)
    #expect(controller.waitingAccessPosition == nil)
    #expect(controller.session.selection.currentItemID == selected.itemID)
    #expect(controller.window?.representedURL == movedChild)
}

// (b) Cancel Reading returns to the previous complete grid; the abandoned scan
// must not keep the recovery identity.
@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix2CancelReadingBackToReadableGridKeepsItsRecoveryIdentity() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close(); f.gate.release() }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne, count: 2)
    let selected = try #require(controller.session.folderScan?.snapshot?.navigationEntries.last)
    controller.session.focus(selected.itemID)
    // Cancel Reading restores the grid view's Current Item, so select it there too, as a user would.
    try recoveryGrid(controller).activate(currentItemID: selected.itemID)
    f.gate.arm(f.b)
    controller.browseRecoveredFolder(f.b, rootID: f.rootB)
    try await recoveryWait { f.gate.isBlocked }
    let state = try #require(controller.window?.contentView?.subviews.compactMap { $0 as? ViewerStateHost }.first)
    try #require(state.buttons.first).performClick(nil)
    f.gate.release()
    try await f.ready(controller, folder: f.childOne, count: 2)
    #expect(controller.window?.representedURL == f.childOne)
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    await f.mount()
    try await f.ready(controller, folder: f.childOne, count: 2)
    #expect(controller.waitingAccessPosition == nil)
    #expect(controller.session.selection.currentItemID == selected.itemID)
    #expect(controller.window?.representedURL == f.childOne)
}

// Audit gpt F2 (round 2): one loss episode announces loss once and recovery
// once. Window B leaves Choose Another Folder open while A recovers; cancelling
// B's panel afterwards must not announce loss again, nor a second recovery.
@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix2PanelLeftOpenDuringRecoveryAnnouncesLossAndRecoveryOnce() async throws {
    let f = try await RecoveryFixture()
    let first = f.controller(), second = f.controller()
    let window = try #require(second.window)
    defer {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        first.window?.close(); window.close(); f.remove()
    }
    second.showWindow(nil)
    first.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    second.browseRecoveredFolder(f.childTwo, rootID: f.rootA)
    try await f.ready(first, folder: f.childOne, count: 2)
    try await f.ready(second, folder: f.childTwo, count: 2)
    var announcements: [String] = []
    first.accessAnnouncementObserver = { announcements.append($0) }
    second.accessAnnouncementObserver = { announcements.append($0) }
    await f.eject()
    try await recoveryWait { recoveryPage(first) != nil && recoveryPage(second) != nil && announcements.count == 1 }
    let page = try #require(recoveryPage(second))
    page.chooseOtherButton.performClick(nil)
    try await recoveryWait { window.attachedSheet is NSOpenPanel }
    await f.mount()
    try await f.ready(first, folder: f.childOne, count: 2)
    try await recoveryWait { announcements.count == 2 }
    #expect(recoveryPage(second) != nil)
    let panel = try #require(window.attachedSheet as? NSOpenPanel)
    window.endSheet(panel, returnCode: .cancel)
    try await recoveryWait { window.attachedSheet == nil }
    try await f.ready(second, folder: f.childTwo, count: 2)
    try await recoveryWait { announcements.count == 2 }
    // Both windows completed; cancelling the panel must not announce again.
    try await Task.sleep(for: .milliseconds(300))
    let loss = try #require(announcements.first)
    #expect(announcements == [loss, String(localized: "Folder Access Restored")])
}


private final class RecoveryDiagnosticTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var messages: [String] { lock.withLock { stored } }
    var diagnostics: AccessDiagnostics { AccessDiagnostics { [self] message, _ in lock.withLock { stored.append(message) } } }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229DiagnosticsAppRefusalThenRecoveryPublishesTruthfulState() async throws {
    let trace = RecoveryDiagnosticTrace(), f = try await RecoveryFixture(diagnostics: trace.diagnostics)
    defer { f.remove() }
    await f.services.monitor.start()
    await f.eject()
    try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.diskNotConnected) }
    f.bookmarks.fail(f.a, true)
    await f.mount()
    // #231: mounted-volume bookmark failure no longer degrades to Unknown.
    try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability != .lost(.diskNotConnected) }
    #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.notFound))
    #expect(trace.messages.contains { $0.contains("AccessRootLost") && $0.contains("cause=diskNotConnected") })
    #expect(trace.messages.contains { $0.contains("AccessRecovery") && $0.contains("outcome=refused") })
    #expect(!trace.messages.contains { $0.contains("AccessRecovery outcome=published") })
    f.bookmarks.fail(f.a, false)
    await f.eject()
    try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.diskNotConnected) }
    await f.mount()
    try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable }
    #expect(trace.messages.contains { $0.contains("AccessRecovery outcome=published") })
    #expect(!trace.messages.joined().contains(f.base.path))
}


@MainActor @Test(.timeLimit(.minutes(3))) func t229DiagnosticsSupersededRecoveryRefusesPublication() async throws {
    let trace = RecoveryDiagnosticTrace(), f = try await RecoveryFixture(diagnostics: trace.diagnostics)
    try await withAsyncTeardown {
        await f.services.monitor.start()
        await f.eject()
        try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.diskNotConnected) }
        let lossCounter = try #require(f.services.monitor.state.snapshot(for: f.rootA)?.counter)
        await f.mounts.pauseEnumeration()
        await f.mount()
        try await recoveryWaitAsync { await f.mounts.paused }
        await f.eject()
        try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.diskNotConnected) }
        try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.counter == lossCounter + 1 }
        await f.mounts.release()
        try await recoveryWait { trace.messages.contains { $0.contains("AccessRecovery outcome=refused") } }
        #expect(!trace.messages.contains { $0.contains("AccessRecovery outcome=published") })
        #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.diskNotConnected))
        await f.mount()
        try await recoveryWait { f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable }
        #expect(trace.messages.contains { $0.contains("AccessRecovery outcome=published") })
    } teardown: {
        f.remove(); await f.mounts.release()
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229R2GridRestoresNonFirstCurrentItemAfterMountTokenChanges() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    try FileManager.default.copyItem(at: f.childOne.appendingPathComponent("one.png"),
        to: f.childOne.appendingPathComponent("three.png"))
    let controller = f.controller(); defer { controller.window?.close() }
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne, count: 3)
    let conditions = FolderViewConditions(sort: .name, direction: .descending, selectedExtensions: ["png"])
    controller.session.setFolderConditions(conditions)
    try await f.ready(controller, folder: f.childOne, count: 2)
    let before = try #require(controller.session.folderScan?.snapshot?.navigationEntries.last)
    controller.session.focus(before.itemID)
    try recoveryGrid(controller).activate(currentItemID: before.itemID)
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    f.gate.nextMount()
    await f.mount()
    try await recoveryWait { controller.waitingAccessPosition == nil }
    let snapshot = try #require(controller.session.folderScan?.snapshot)
    let current = snapshot.entries.first { $0.itemID == controller.session.selection.currentItemID }
    #expect(snapshot.version.folder.standardizedFileURL.path == f.childOne.standardizedFileURL.path)
    #expect(current?.url.standardizedFileURL.path == before.url.standardizedFileURL.path)
    #expect(current?.resourceIdentifier != before.resourceIdentifier)
    #expect(controller.session.folderConditions == conditions)
    await f.eject()
    try await recoveryWait { recoveryPage(controller) != nil }
    f.gate.nextMount()
    await f.mount()
    try await recoveryWait { controller.waitingAccessPosition == nil }
    let repeated = controller.session.folderScan?.snapshot?.entries.first { $0.itemID == controller.session.selection.currentItemID }
    #expect(repeated?.url.standardizedFileURL.path == before.url.standardizedFileURL.path)
}


// #230: these tests supply the system panel's result to the production
// continuation. The real chooser configuration/cancel is exercised separately.
@MainActor private func t230OpenPositionBeforeLoss(_ f: RecoveryFixture, _ controller: CanvasWindowController) async throws -> ItemID {
    controller.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(controller, folder: f.childOne, count: 2)
    controller.session.setFolderConditions(.init(sort: .name, direction: .descending, selectedExtensions: ["png", "jpg"]))
    try await f.ready(controller, folder: f.childOne, count: 2)
    let entries = try #require(controller.session.folderScan?.snapshot?.navigationEntries)
    let chosen = try #require(entries.last)
    controller.session.focus(chosen.itemID)
    #expect(controller.route(.enter, from: .key))
    try await recoveryWait { controller.session.mode == .viewing && controller.hasImage && controller.session.imageLoader.presented != nil }
    return chosen.itemID
}
@MainActor private func t230DenyRoot(_ f: RecoveryFixture, _ controller: CanvasWindowController) async throws {
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.a.path)
    await f.services.monitor.reportReadFailure(f.rootA, from: f.services.monitor.state.stamp(for: f.rootA),
        error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
    try await recoveryWait { recoveryPage(controller) != nil }
    #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.accessExpired))
    #expect(!controller.hasImage && controller.session.mode == .browsing)
    #expect(controller.window?.representedURL == nil && controller.window?.title == "Picsee")
    #expect(controller.inspector.name == nil && controller.inspector.value == .unknown)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [false, true])
func t230SameIdentityReselectRestoresOriginalPosition(_ renamed: Bool) async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close() }
    let item = try await t230OpenPositionBeforeLoss(f, controller)
    let conditions = controller.session.folderConditions
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.a.path) }
    try await t230DenyRoot(f, controller)
    #expect(recoveryPage(controller)?.titleLabel.stringValue == String(localized: "Access Has Expired"))
    #expect(recoveryPage(controller)?.buttons.count == 1)
    #expect(controller.waitingAccessPosition?.folderReference != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.a.path)
    var selected = f.a
    if renamed {
        selected = f.base.appendingPathComponent("ReselectedMovedRoot")
        try await f.moveRoot(to: selected)
    }
    controller.completeAccessFolderSelection(selected, reselect: true)
    try await recoveryWait { controller.waitingAccessPosition == nil && controller.session.folderScan?.snapshot?.isComplete == true }
    #expect(controller.session.folderScan?.snapshot?.version.folder == selected.appendingPathComponent("One"))
    #expect(controller.session.currentItemID == item)
    #expect(controller.session.folderConditions == conditions)
    #expect(controller.session.mode == .browsing && !controller.hasImage)
    #expect(await f.services.files.records().count == 2)
    #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .readable)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["other", "replacement", "missing-proof"])
func t230DifferentIdentitySelectionOpensNormallyPreservingLostRoot(_ kind: String) async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); defer { controller.window?.close() }
    if kind == "missing-proof" {
        await f.services.monitor.register(f.rootA)
        _ = f.services.monitor.state.reportRootFailure(f.rootA, cause: .accessExpired, from: f.services.monitor.state.stamp(for: f.rootA))
        controller.requestFolderReconnection(rootID: f.rootA, lastKnownFolder: f.a, displayName: "RootA")
        try await recoveryWait { recoveryPage(controller) != nil }
        #expect(controller.waitingAccessPosition?.folderReference == nil)
    } else {
        _ = try await t230OpenPositionBeforeLoss(f, controller)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.a.path) }
        try await t230DenyRoot(f, controller)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.a.path)
    }
    let original = try #require(await f.services.files.records().first { $0.id == f.rootA })
    let lost = f.services.monitor.state.snapshot(for: f.rootA)
    var selected = f.b
    if kind == "replacement" {
        let moved = f.base.appendingPathComponent("OriginalStillLost")
        try await f.moveRoot(to: moved)
        try FileManager.default.createDirectory(at: f.a, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.b.appendingPathComponent("other.png"), to: f.a.appendingPathComponent("new.png"))
        selected = f.a
    } else if kind == "missing-proof" { selected = f.a }
    controller.completeAccessFolderSelection(selected, reselect: true)
    try await recoveryWait { controller.waitingAccessPosition == nil && controller.session.folderScan?.snapshot?.isComplete == true }
    #expect(controller.session.folderScan?.snapshot?.version.folder == selected)
    #expect(controller.session.folderScan?.snapshot?.version.rootID != f.rootA)
    #expect(await f.services.files.records().first { $0.id == f.rootA } == original)
    #expect(f.services.monitor.state.snapshot(for: f.rootA) == lost)
    #expect(await f.services.files.records().count == (kind == "other" ? 2 : 3))
    #expect(controller.window?.attachedSheet == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t230ExpiredPanelCancelPreservesStateAndButtons() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let controller = f.controller(); let window = try #require(controller.window)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.a.path)
        if let panel = window.attachedSheet { window.endSheet(panel, returnCode: .cancel) }
        window.close()
    }
    _ = try await t230OpenPositionBeforeLoss(f, controller)
    try await t230DenyRoot(f, controller)
    let page = try #require(recoveryPage(controller)), lost = f.services.monitor.state.snapshot(for: f.rootA)
    let records = await f.services.files.records(), current = controller.waitingAccessPosition?.currentItemID
    for _ in 0..<2 {
        page.reselectButton.performClick(nil)
        try await recoveryWait { window.attachedSheet is NSOpenPanel }
        let panel = try #require(window.attachedSheet as? NSOpenPanel)
        #expect(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection)
        window.endSheet(panel, returnCode: .cancel)
        try await recoveryWait { window.attachedSheet == nil }
        #expect(recoveryPage(controller) === page && page.buttons == [page.reselectButton])
        #expect(window.firstResponder === page.reselectButton)
        #expect(f.services.monitor.state.snapshot(for: f.rootA) == lost)
        #expect(await f.services.files.records() == records)
        #expect(controller.waitingAccessPosition?.currentItemID == current)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t230AccessExpiredCatalogHasPinnedChineseAndEnglishCopy() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    for (key, chinese) in [
        ("Access Has Expired", "授权失效"),
        ("Access has expired. Choose this folder again to restore access; picsee will return to where you left off.", "访问权限已失效。重新选择这个文件夹即可恢复，picsee 会回到你刚才的位置。")
    ] {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for (language, expected) in [("en", key), ("zh-Hans", chinese)] {
            let translation = try #require(localizations[language] as? [String: Any])
            let unit = try #require(translation["stringUnit"] as? [String: Any])
            #expect(unit["value"] as? String == expected)
        }
    }
}


@MainActor private func t231Lose(_ f: RecoveryFixture, _ c: CanvasWindowController) async throws {
    _ = try await t230OpenPositionBeforeLoss(f, c)
    f.bookmarks.fail(f.a, true)
    _ = f.services.monitor.state.reportRootFailure(f.rootA, cause: .notFound, from: f.services.monitor.state.stamp(for: f.rootA))
    try await recoveryWait { recoveryPage(c) != nil }
}
@MainActor private func t231Strip(_ c: CanvasWindowController) throws -> AccessRebindStripView {
    try #require(try recoveryShell(c).mainContent.subviews.compactMap { $0 as? AccessRebindStripView }.first { !$0.isHidden })
}
@MainActor @Test(.timeLimit(.minutes(3)))
func t231Fix1ForegroundFollowsInactiveRootThenRebindRemapsHistoricalRecent() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    let childRecent = RecentFolder(rootID: f.rootA, url: f.childOne, displayName: "One", openedAt: Date(timeIntervalSince1970: 1234))
    try await f.services.recent.add(childRecent)
    c.browseRecoveredFolder(f.b, rootID: f.rootB)
    try await f.ready(c, folder: f.b)
    let moved = f.base.appendingPathComponent("Renamed", isDirectory: true)
    try await f.moveRoot(to: moved)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try await recoveryWaitAsync { await f.services.files.rootURL(f.rootA)?.path == moved.path }
    #expect(c.session.folderScan?.snapshot?.version.rootID == f.rootB)
    #expect(try await f.services.recent.load().contains(childRecent))
    let replacement = f.base.appendingPathComponent("Replacement", isDirectory: true)
    try FileManager.default.copyItem(at: moved, to: replacement)
    try FileManager.default.removeItem(at: moved)
    f.bookmarks.fail(moved, true)
    c.openRecent(childRecent)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA && recoveryPage(c) != nil }
    // Reconnection first renders an unknown cause, then classifies the root asynchronously.
    try await recoveryWait { c.accessLossCause == .notFound }
    #expect(c.accessLossCause == .notFound)
    // Observe the committed transaction before the new scan remembers its root.
    f.gate.arm(replacement)
    defer { f.gate.release() }
    await f.mounts.pauseEnumeration()
    try await withAsyncTeardown {
        c.completeAccessFolderSelection(replacement, reselect: true)
        try await recoveryWaitAsync { await f.mounts.paused }
        // A paused mount query can belong to a foreground check, so await actual commit.
        try await recoveryWaitAsync {
            let records = await f.services.files.records()
            return !records.contains { $0.id == f.rootA } && records.contains { $0.id != f.rootB }
        }
        let destination = try #require(await f.services.files.records().first { $0.id != f.rootB })
        let committed = try await f.services.recent.load()
        #expect(committed.allSatisfy { $0.rootID != f.rootA })
        #expect(committed.contains { $0.rootID == destination.id && $0.url.path == replacement.appendingPathComponent("One").path })
        f.gate.release()
        await f.mounts.release()
        try await f.ready(c, folder: replacement)
        let recent = try await f.services.recent.load()
        #expect(recent.allSatisfy { $0.rootID != f.rootA })
        #expect(recent.filter { $0.rootID == destination.id && $0.url.path == replacement.path }.count == 1)
        #expect(try t231Strip(c).superview != nil)
    } teardown: {
        await f.mounts.release()
    }
}
@MainActor @Test(.timeLimit(.minutes(3))) func t231NotFoundCopyAndCancelLeaveRecoveryActions() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    var failures: [(AccessRootID, String, String)] = []
    c.accessTransactionFailureReporter = { failures.append(($0, $1, $2)) }
    try await t231Lose(f, c)
    let records = await f.services.files.records(), recent = try await f.services.recent.load()
    let page = try #require(recoveryPage(c))
    #expect(page.titleLabel.stringValue == String(localized: "Not Found"))
    #expect(page.buttons.map(\.title) == [String(localized: "Choose at New Location…"), String(localized: "Choose Another Folder…")])
    #expect(!page.detailLabel.stringValue.lowercased().contains("moved"))
    c.completeAccessFolderSelection(nil, reselect: true)
    #expect(c.accessLossCause == .notFound && c.waitingAccessPosition?.rootID == f.rootA)
    #expect(page.buttons.count == 2 && page.buttons.allSatisfy(\.isEnabled))
    #expect(await f.services.files.records() == records)
    #expect(try await f.services.recent.load() == recent)
    #expect(c.window?.firstResponder === page.reselectButton)
    #expect(failures.isEmpty)
}
@MainActor @Test(.timeLimit(.minutes(3)), arguments: [false, true])
func t231AppFreshRebindMergeAndUndoRestoreLostPosition(_ merge: Bool) async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    try await t231Lose(f, c)
    let old = try #require(c.waitingAccessPosition)
    let records = await f.services.files.records(), recent = try await f.services.recent.load()
    let target = merge ? f.b : f.base.appendingPathComponent("New", isDirectory: true)
    if !merge { try FileManager.default.copyItem(at: f.b, to: target) }
    c.completeAccessFolderSelection(target, reselect: true)
    try await recoveryWait { c.waitingAccessPosition == nil && c.session.folderScan?.snapshot?.isComplete == true }
    #expect(await f.services.files.records().allSatisfy { $0.id != f.rootA })
    #expect(c.session.folderScan?.snapshot?.version.folder == target)
    let expectedID = merge ? f.rootB : await f.services.files.records().first { $0.id != f.rootB }?.id
    #expect(c.session.folderScan?.snapshot?.version.rootID == expectedID)
    #expect(!c.hasImage && c.session.currentItemID != old.currentItemID)
    let strip = try t231Strip(c), grid = try recoveryGrid(c)
    #expect(strip.messageLabel.stringValue == String(format: String(localized: "Updated to %@"), target.path))
    #expect(strip.frame.minY >= grid.frame.maxY)
    strip.undoButton.performClick(nil)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA }
    #expect(c.accessLossCause == .notFound)
    #expect(c.waitingAccessPosition?.folderURL == old.folderURL)
    #expect(c.waitingAccessPosition?.currentItemID == old.currentItemID)
    #expect(c.waitingAccessPosition?.conditions == old.conditions)
    #expect(c.waitingAccessPosition?.counter != old.counter)
    #expect(await f.services.files.records() == records)
    #expect(try await f.services.recent.load() == recent)
    #expect(!c.hasImage && c.inspector.name == nil && c.window?.representedURL == nil)
    #expect(strip.superview == nil && !strip.undoButton.isEnabled)
}
@MainActor @Test(.timeLimit(.minutes(3))) func t231OtherFolderOpensNormallyAndOriginalRemainsLost() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    try await t231Lose(f, c)
    c.completeAccessFolderSelection(f.b, reselect: false)
    try await f.ready(c, folder: f.b)
    #expect(await f.services.files.records().contains { $0.id == f.rootA })
    #expect(f.services.monitor.state.snapshot(for: f.rootA)?.availability == .lost(.notFound))
    #expect(try recoveryShell(c).mainContent.subviews.allSatisfy { !($0 is AccessRebindStripView) })
}
@MainActor @Test(.timeLimit(.minutes(3))) func t231StripPerWindowDismissAndUndoRetiresLaterGrantAuthority() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(), other = f.controller(); defer { c.window?.close(); other.window?.close() }
    try await t231Lose(f, c)
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b)
    let strip = try t231Strip(c)
    #expect(try recoveryShell(other).mainContent.subviews.allSatisfy { !($0 is AccessRebindStripView) })
    let later = f.base.appendingPathComponent("Later", isDirectory: true)
    try FileManager.default.copyItem(at: f.b, to: later)
    other.openGrantedFolder(later)
    try await f.ready(other, folder: later)
    let id = try #require(other.session.folderScan?.snapshot?.version.rootID)
    let permit = try #require(f.services.monitor.state.permit(for: id))
    strip.undoButton.performClick(nil)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA }
    #expect(!permit.isCurrent)
    #expect(other.waitingAccessPosition?.rootID == id && !other.hasImage)
    #expect(await f.services.files.records().allSatisfy { $0.id != id })
}

@MainActor @Test(.timeLimit(.minutes(3))) func t231RebindFailureAndUndoFailureRemainRecoverable() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    var failures: [(AccessRootID, String, String)] = []
    c.accessTransactionFailureReporter = { failures.append(($0, $1, $2)) }
    try await t231Lose(f, c)
    let marker = f.base.appendingPathComponent("recent.json.schema")
    let originalMarker = try? Data(contentsOf: marker)
    try Data("{\"schemaVersion\":999}".utf8).write(to: marker)
    c.completeAccessFolderSelection(f.b, reselect: true)
    // Await the actual FileAccess actor's completion, then the controller's main actor continuation.
    await Task.yield()
    try await recoveryWait { recoveryPage(c)?.buttons.allSatisfy(\.isEnabled) == true }
    #expect(c.waitingAccessPosition?.rootID == f.rootA)
    #expect(await f.services.files.records().contains { $0.id == f.rootA })
    #expect(try recoveryShell(c).mainContent.subviews.allSatisfy { !($0 is AccessRebindStripView) })
    #expect(failures.count == 1)
    #expect(failures.first?.0 == f.rootA && failures.first?.1 == "rebind")
    #expect(failures.first?.2 == AccessDiagnostics.errorKind(StoredSchema.UnsupportedVersion(version: 999)))
    if let originalMarker { try originalMarker.write(to: marker) }
    else { try FileManager.default.removeItem(at: marker) }
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b)
    let strip = try t231Strip(c)
    #expect(failures.count == 1)
    let rootsMarker = f.base.appendingPathComponent("roots.json.schema")
    let rootMarker = try? Data(contentsOf: rootsMarker)
    try Data("{\"schemaVersion\":999}".utf8).write(to: rootsMarker)
    strip.undoButton.performClick(nil)
    try await recoveryWait { strip.undoButton.isEnabled }
    #expect(c.waitingAccessPosition == nil)
    let reboundRecords = await f.services.files.records()
    #expect(strip.superview != nil && reboundRecords.allSatisfy { $0.id != f.rootA })
    #expect(failures.count == 2)
    #expect(failures.last?.0 == f.rootA && failures.last?.1 == "undo")
    #expect(failures.last?.2 == AccessDiagnostics.errorKind(StoredSchema.UnsupportedVersion(version: 999)))
    if let rootMarker { try rootMarker.write(to: rootsMarker) }
    else { try FileManager.default.removeItem(at: rootsMarker) }
    strip.undoButton.performClick(nil)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA }
    #expect(c.accessLossCause == .notFound && strip.superview == nil)
    #expect(failures.count == 2)
}
@MainActor @Test(.timeLimit(.minutes(3))) func t231StripSurvivesResizeAndCloseRetiresControls() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    try await t231Lose(f, c)
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b)
    let strip = try t231Strip(c)
    c.window?.setContentSize(NSSize(width: 800, height: 680))
    c.windowDidResize(Notification(name: NSWindow.didResizeNotification))
    #expect(try t231Strip(c) === strip)
    #expect(strip.frame.minY >= (try recoveryGrid(c)).frame.maxY)
    #expect(c.window?.makeFirstResponder(strip.undoButton) == true)
    c.window?.selectNextKeyView(strip.undoButton)
    #expect(c.window?.firstResponder === strip.closeButton)
    #expect(c.window?.makeFirstResponder(strip.closeButton) == true)
    strip.closeButton.performClick(nil)
    #expect(strip.superview == nil && !strip.undoButton.isEnabled && !strip.closeButton.isEnabled)
    #expect(strip.undoButton.nextKeyView == nil && strip.closeButton.nextKeyView == nil)
    #expect(c.window?.firstResponder !== strip.closeButton)
    #expect(try recoveryShell(c).sortButton.nextKeyView !== strip.undoButton)
    #expect(await f.services.files.records().allSatisfy { $0.id != f.rootA })
}

/// PR #304 CI: a footer status change re-ran the shell's layout, which reset every main-content view to the full main
/// frame and left the strip covering the grid. Any shell layout pass must keep the strip above the grid.
@MainActor @Test(.timeLimit(.minutes(3))) func t231StripStaysAboveGridAfterFooterStatusRelayout() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    try await t231Lose(f, c)
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b)
    let strip = try t231Strip(c), shell = try recoveryShell(c), grid = try recoveryGrid(c)
    for step in ["current file", "search status", "reading status"] {
        switch step {
        case "current file": shell.setCurrentFile("DSC_0001.jpg")
        case "search status": shell.setSearchStatus(resultCount: 3, term: "")
        default: shell.setReadingStatus(false)
        }
        shell.layoutSubtreeIfNeeded()
        let main = shell.mainContent.bounds, footer = shell.footer.bounds.height
        #expect(strip.frame == NSRect(x: main.minX, y: main.maxY - 44, width: main.width, height: 44), "\(step): strip frame")
        #expect(grid.frame == NSRect(x: main.minX, y: main.minY - footer, width: main.width,
            height: main.height - 44 + footer), "\(step): grid frame")
        #expect(strip.frame.minY >= grid.frame.maxY, "\(step): strip above grid")
    }
}

private struct Issue314Scanner: FolderScanning {
    let browser: FolderBrowser
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        if folder.lastPathComponent == "Failed" {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        }
        try await browser.scan(in: folder, root: root, options: options, emit: emit)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue314AppGridStaysUnderBottomBarThroughControllerLayout() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(), window = try #require(c.window)
    defer {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        window.close()
    }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    for index in 1...23 {
        try FileManager.default.copyItem(at: fixture, to: f.b.appendingPathComponent(String(format: "%02d.png", index)))
    }
    let empty = f.b.appendingPathComponent("Empty", isDirectory: true)
    let failed = f.b.appendingPathComponent("Failed", isDirectory: true)
    for folder in [empty, failed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    c.folderScanningOverride = Issue314Scanner(browser: f.services.browser)
    window.setContentSize(NSSize(width: 1280, height: 800))
    c.showWindow(nil)
    window.orderFrontRegardless()
    let shell = try recoveryShell(c), grid = try recoveryGrid(c)
    let state = try #require(window.contentView?.subviews.compactMap { $0 as? ViewerStateHost }.first)

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        shell.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
    }
    func expectMainFrame(_ view: NSView, _ step: String) {
        layout()
        #expect(view.convert(view.bounds, to: shell) == shell.mainFrame, "\(step): state frame")
    }
    func expectExtendedGrid(_ step: String, topInset: CGFloat = 0) throws {
        layout()
        let frame = grid.convert(grid.bounds, to: shell)
        #expect(abs(frame.minY - shell.footer.frame.minY) < 0.01, "\(step): Grid extends to the window bottom")
        #expect(abs(frame.maxY - (shell.bounds.maxY - topInset)) < 0.01,
            "\(step): Grid top respects the title strip and rebind strip")
        let scroll = try #require(grid.collectionView.enclosingScrollView)
        #expect(scroll.contentInsets.bottom == 40, "\(step): Bottom Bar inset")
        let lastIndex = grid.displayedItemIDs.count - 1
        let endOffset = max(0, grid.collectionView.bounds.height - scroll.contentView.bounds.height
            + scroll.contentInsets.bottom)
        #expect(endOffset > 0, "\(step): fixture scrolls")
        grid.restoreContentOffset(NSPoint(x: 0, y: endOffset))
        grid.layoutSubtreeIfNeeded()
        var lastFrame = grid.collectionView.convert(grid.collectionView.frameForItem(at: lastIndex), to: shell)
        #expect(lastFrame.minY >= shell.footer.frame.maxY + 30 - 0.5,
            "\(step): last row at the end is behind the Bottom Bar: \(lastFrame)")

        grid.restoreContentOffset(.zero)
        grid.activate(currentItemID: grid.itemID(at: 0))
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        for _ in 1..<grid.displayedItemIDs.count { grid.collectionView.keyDown(with: right) }
        #expect(grid.currentItemID == grid.itemID(at: lastIndex), "\(step): keyboard selects the last item")
        lastFrame = grid.collectionView.convert(grid.collectionView.frameForItem(at: lastIndex), to: shell)
        #expect(lastFrame.minY >= shell.footer.frame.maxY - 0.5,
            "\(step): keyboard-selected last item clears the Bottom Bar: \(lastFrame)")
        grid.restoreContentOffset(NSPoint(x: 0, y: endOffset))
        grid.layoutSubtreeIfNeeded()
        lastFrame = grid.collectionView.convert(grid.collectionView.frameForItem(at: lastIndex), to: shell)
        #expect(lastFrame.minY >= shell.footer.frame.maxY + 30 - 0.5,
            "\(step): keyboard-selected last item at the end has 40 + 30 pt clearance: \(lastFrame)")
    }

    f.gate.arm(f.b)
    c.browseRecoveredFolder(f.b, rootID: f.rootB)
    try await recoveryWait { c.session.folderScan?.isReadingFolder == true }
    expectMainFrame(state, "Reading")
    f.gate.release()
    try await f.ready(c, folder: f.b, count: 24)
    try expectExtendedGrid("ordinary folder")
    window.setContentSize(NSSize(width: 800, height: 680))
    c.windowDidResize(Notification(name: NSWindow.didResizeNotification))
    try expectExtendedGrid("800×680 resize")

    c.browseRecoveredFolder(empty, rootID: f.rootB)
    try await f.ready(c, folder: empty, count: 0)
    expectMainFrame(state, "empty")
    expectMainFrame(shell.emptyFolderView, "empty shell page")
    c.browseRecoveredFolder(failed, rootID: f.rootB)
    try await recoveryWait { c.session.folderScan?.failure != nil }
    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    expectMainFrame(state, "failed")

    try await t231Lose(f, c)
    expectMainFrame(try #require(recoveryPage(c)), "Lost Access")
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b, count: 24)
    let strip = try t231Strip(c), main = shell.mainContent.bounds
    #expect(strip.frame == NSRect(x: main.minX, y: main.maxY - 44, width: main.width, height: 44),
        "rebind: strip takes the top 44 pt")
    try expectExtendedGrid("visible rebind strip", topInset: 44)
}

/// Fix round 5 (device run parity-281-fix4-10301906): page 26 kept the reading footer, `–` and `Reading…`, because the
/// read that ended on the lost-access page never cleared it. #332: page 26's footer status is `–` / 无法访问.
@MainActor @Test(.timeLimit(.minutes(3))) func t281Fix5LostAccessPageFooterIsNotReading() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    func expectLostFooter(_ step: String) throws {
        let shell = try recoveryShell(c)
        shell.layoutSubtreeIfNeeded()
        let name = try #require(t281Fix5Label("grid.current-file-status", in: shell))
        let count = try #require(t281Fix5Label("grid.folder-count", in: shell))
        #expect(!name.isHidden && name.stringValue == "\u{2013}", "\(step): name \(name.stringValue)")
        #expect(!count.isHidden && count.stringValue == String(localized: "Unavailable"), "\(step): count \(count.stringValue)")
        #expect(count.stringValue != String(localized: "Reading…"), "\(step): reading footer")
        #expect(!shell.searchField.isEnabled && !shell.sortButton.isEnabled, "\(step): footer actions as on main")
    }
    try await t231Lose(f, c)
    try expectLostFooter("page 26")
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b)
    let strip = try t231Strip(c)
    strip.undoButton.performClick(nil)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA && recoveryPage(c) != nil }
    try expectLostFooter("undo back to page 26")
}
/// #332 / page 26: cancelling either replacement route restores the lost footer and sidebar row.
@MainActor @Test(.timeLimit(.minutes(3)), arguments: [false, true])
func t332CancelReadingRestoresLostAccessFooterAndSidebar(reselect: Bool) async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { f.gate.release(); c.window?.close() }
    try await t231Lose(f, c)
    let position = try #require(c.waitingAccessPosition)
    let cause = try #require(c.accessLossCause)
    let shell = try recoveryShell(c)
    let parent = shell.folderTree.parent
    f.gate.arm(f.b)
    c.completeAccessFolderSelection(f.b, reselect: reselect)
    try await recoveryWait { f.gate.isBlocked }
    let state = try #require(c.window?.contentView?.subviews.compactMap { $0 as? ViewerStateHost }.first)
    let cancel = try #require(state.buttons.first)
    cancel.performClick(nil)
    func expectRestored() throws {
        #expect(recoveryPage(c) != nil)
        #expect(c.waitingAccessPosition?.rootID == position.rootID)
        #expect(c.waitingAccessPosition?.folderURL == position.folderURL)
        #expect(c.accessLossCause == cause)
        shell.layoutSubtreeIfNeeded()
        let name = try #require(t281Fix5Label("grid.current-file-status", in: shell))
        let count = try #require(t281Fix5Label("grid.folder-count", in: shell))
        #expect(!name.isHidden && name.stringValue == "\u{2013}")
        #expect(!count.isHidden && count.stringValue == String(localized: "Unavailable"))
        #expect(!shell.searchField.isEnabled && !shell.sortButton.isEnabled)
        #expect(!shell.folderTree.isHidden)
        let row = try #require(shell.folderTree.rows.first { $0.current })
        #expect(row.folderURL == position.folderURL && row.accessLossCause == cause)
        #expect(!row.warningGlyph.isHidden && row.countLabel.isHidden)
        #expect(shell.folderTree.parent == parent && shell.folderTree.children.isEmpty)
    }
    try expectRestored()
    f.gate.release()
    // Let the abandoned real read return; its stale completion cannot replace the restored page.
    try await Task.sleep(for: .milliseconds(100))
    try expectRestored()
}

@MainActor private func t281Fix5Label(_ id: String, in view: NSView) -> NSTextField? {
    if view.accessibilityIdentifier() == id || view.identifier?.rawValue == id { return view as? NSTextField }
    return view.subviews.lazy.compactMap { t281Fix5Label(id, in: $0) }.first
}

@MainActor @Test(.timeLimit(.minutes(3))) func t231NotFoundRealShellFramesAndLanguages() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for chinese in [false, true] {
                let c = f.controller(); defer { c.window?.close() }
                f.bookmarks.fail(f.a, false)
                await f.services.monitor.reauthorize(f.rootA)
                // Open the original authorized root, rather than creating a child Access Root.
                c.browseRecoveredFolder(f.childOne, rootID: f.rootA)
                try await f.ready(c, folder: f.childOne)
                _ = f.services.monitor.state.reportRootFailure(f.rootA, cause: .notFound, from: f.services.monitor.state.stamp(for: f.rootA))
                try await recoveryWait { recoveryPage(c) != nil }
                c.window?.setContentSize(size)
                c.window?.appearance = NSAppearance(named: appearance)
                c.windowDidResize(Notification(name: NSWindow.didResizeNotification))
                let page = try #require(recoveryPage(c))
                page.display(cause: .notFound, text: .init(title: chinese ? "找不到" : "Not Found",
                    detail: chinese ? "picsee 找不到“RootA”。请在新位置选择，或选择其他文件夹以继续。" : "picsee can’t find “RootA”. Choose its location, or choose another folder to continue.", waiting: "",
                    reselect: chinese ? "在新位置选择…" : "Choose at New Location…", chooseOther: chinese ? "选择其他文件夹…" : "Choose Another Folder…"))
                page.layoutSubtreeIfNeeded()
                let shell = try recoveryShell(c)
                #expect(page.frame == shell.mainContent.bounds)
                // #230 page26 .empty-state: centered block +19px visual offset.
                let union = [page.iconView, page.titleLabel, page.detailLabel, page.reselectButton, page.chooseOtherButton].reduce(NSRect.null) { $0.union($1.frame) }
                #expect(abs(union.midY - (page.bounds.midY + 19)) < 1)
                #expect(page.bounds.contains(union))
                // .empty-state h2 margin-top:18; p margin-top:9; .mock-actions margin-top:18/gap:16.
                #expect(page.iconView.frame.minY - page.titleLabel.frame.maxY == 18)
                #expect(page.titleLabel.frame.minY - page.detailLabel.frame.maxY == 9)
                #expect(page.detailLabel.frame.minY - page.reselectButton.frame.maxY == 18)
                #expect(page.chooseOtherButton.frame.minX - page.reselectButton.frame.maxX == 16)
                // .recovery-state p max-width:460; icon32; h2 16 medium; p13/22.1.
                #expect(page.detailLabel.frame.width == 460 && page.iconView.frame.width == 32)
                #expect(page.titleLabel.font == NSFont.systemFont(ofSize: 16, weight: .medium))
                let paragraph = try #require(page.detailLabel.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                #expect(paragraph.minimumLineHeight == 22.1 && paragraph.maximumLineHeight == 22.1)
                #expect(page.titleLabel.textColor == DesignColor.textPrimary.nsColor)
                #expect(page.waitingLabel.superview == nil && page.buttons.count == 2)
            }
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t231StaleSelectionNavigationAndClosedWindowCannotCommit() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    try await t231Lose(f, c)
    let later = f.base.appendingPathComponent("Later", isDirectory: true)
    try FileManager.default.copyItem(at: f.b, to: later)
    c.completeAccessFolderSelection(f.b, reselect: true)
    c.openGrantedFolder(later)
    try await f.ready(c, folder: later)
    #expect(await f.services.files.records().contains { $0.id == f.rootA })
    #expect(c.session.folderScan?.snapshot?.version.folder == later)
    #expect(try recoveryShell(c).mainContent.subviews.allSatisfy { !($0 is AccessRebindStripView) })
    let second = f.controller()
    second.requestFolderReconnection(rootID: f.rootA, lastKnownFolder: f.childOne, displayName: "RootA")
    try await recoveryWait { recoveryPage(second) != nil }
    second.completeAccessFolderSelection(f.b, reselect: true, replacing: true)
    second.window?.close()
    await Task.yield()
    #expect(await f.services.files.records().contains { $0.id == f.rootA })
}

@MainActor @Test(.timeLimit(.minutes(3))) func t231MergeKeepsReadableDestinationWindowAuthority() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(), other = f.controller(); defer { c.window?.close(); other.window?.close() }
    other.browseRecoveredFolder(f.b, rootID: f.rootB)
    try await f.ready(other, folder: f.b)
    let context = try await f.services.monitor.readContext(for: f.rootB)
    try await t231Lose(f, c)
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await f.ready(c, folder: f.b)
    #expect(context.permit.isCurrent)
    #expect(f.services.monitor.state.mayDeliver(context.stamp))
    #expect(other.waitingAccessPosition == nil && other.session.folderScan?.snapshot?.version.rootID == f.rootB)
}
@MainActor @Test(.timeLimit(.minutes(3))) func t231ExplicitTrashGrantAdmitsButAutomaticCheckRejects() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let folder = base.appendingPathComponent("ExplicitTrash", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    var trashed: NSURL?
    try fm.trashItem(at: folder, resultingItemURL: &trashed)
    let selected = try #require(trashed as URL?)
    defer { try? fm.removeItem(at: selected) }
    let boundary = RecoveryBookmarks()
    let files = try FileAccess(scope: boundary, bookmarks: boundary, store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T231-AppTrash")
    let services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recents.json")), browser: FolderBrowser(),
        watch: WatchHub(access: files, source: RecoveryWatchSource(), scheduler: DispatchWatchScheduler()), mounts: RecoveryMounts(), selectionScope: boundary)
    let id = try await services.grant(selected)
    #expect(services.monitor.state.snapshot(for: id)?.availability == .readable)
    let lease = try await files.acquire(.root(id, file: selected))
    #expect(lease.url.standardizedFileURL == selected.standardizedFileURL)
    await files.release(lease)
    await services.monitor.reauthorize(id)
    #expect(services.monitor.state.snapshot(for: id)?.availability == .lost(.notFound))
    #expect(services.monitor.state.permit(for: id) == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t231CommittedDestinationReadFailureKeepsUndo() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close(); f.bookmarks.fail(f.b, false) }
    try await t231Lose(f, c)
    await f.mounts.pauseEnumeration()
    c.completeAccessFolderSelection(f.b, reselect: true)
    try await recoveryWaitAsync { await f.mounts.paused }
    // Persistence has committed; a subsequent reader failure cannot erase Undo.
    #expect(await f.services.files.records().allSatisfy { $0.id != f.rootA })
    f.bookmarks.fail(f.b, true)
    await f.mounts.release()
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootB }
    let strip = try t231Strip(c)
    #expect(strip.undoButton.isEnabled && !c.hasImage)
    strip.undoButton.performClick(nil)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA }
    #expect(c.accessLossCause == .notFound)
    #expect(await f.services.files.records().contains { $0.id == f.rootA })
}

@MainActor @Test(.timeLimit(.minutes(3))) func t231ExplicitTrashRebindOpensGridThenForegroundLosesAndUndoRestores() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    try await t231Lose(f, c)
    let folder = f.base.appendingPathComponent("Explicit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.copyItem(at: f.b, to: folder)
    var trashed: NSURL?
    try FileManager.default.trashItem(at: folder, resultingItemURL: &trashed)
    let selected = try #require(trashed as URL?)
    defer { try? FileManager.default.removeItem(at: selected) }
    c.completeAccessFolderSelection(selected, reselect: true)
    try await recoveryWait { c.session.folderScan?.snapshot?.isComplete == true || (c.waitingAccessPosition != nil && c.waitingAccessPosition?.rootID != f.rootA) }
    #expect(c.waitingAccessPosition == nil, "explicit selected Trash should open; cause=\(String(describing: c.accessLossCause))")
    let snapshot = try #require(c.session.folderScan?.snapshot)
    #expect(snapshot.version.folder.path == selected.path)
    #expect(try recoveryGrid(c).isHiddenOrHasHiddenAncestor == false)
    print("t231 explicit-trash stage=grid actualDirectory=\(snapshot.version.folder.hasDirectoryPath) selectedDirectory=\(selected.hasDirectoryPath)")
    let id = try #require(c.session.folderScan?.snapshot?.version.rootID)
    let strip = try t231Strip(c)
    #expect(c.waitingAccessPosition == nil && !c.hasImage)
    #expect(try recoveryGrid(c).displayedItemIDs.count == 1)
    #expect(f.services.monitor.state.snapshot(for: id)?.availability == .readable)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try await recoveryWait { c.waitingAccessPosition?.rootID == id }
    print("t231 explicit-trash stage=foregroundLost")
    #expect(c.accessLossCause == .notFound && !c.hasImage && c.inspector.name == nil)
    #expect(strip.superview != nil && strip.undoButton.isEnabled)
    #expect(c.window?.makeFirstResponder(strip.closeButton) == true)
    strip.undoButton.performClick(nil)
    try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA }
    print("t231 explicit-trash stage=undo")
    #expect(c.accessLossCause == .notFound)
    #expect(await f.services.files.records().contains { $0.id == f.rootA })
    #expect(strip.superview == nil)
}


/// Each instance observes one known readable-root pass. The last readiness
/// callback is synchronous on MainActor; with exactly these saved roots there
/// is no further await before AccessMonitor clears its recheck task. A resumed
/// MainActor waiter therefore starts its next phase after that job has finished.
@MainActor private final class RecoveryForegroundPhase {
    private let monitor: AccessMonitor
    private let expectedRoots: Set<AccessRootID>
    private var observation: UUID?
    private(set) var observedRoots: Set<AccessRootID> = []
    private(set) var isWaiting = false
    var hasObserver: Bool { observation != nil }
    var isComplete: Bool { observedRoots == expectedRoots }

    init(monitor: AccessMonitor, roots: Set<AccessRootID>) {
        self.monitor = monitor; expectedRoots = roots
    }

    func run(trigger: @MainActor () -> Void = {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    }) async throws {
        let (events, completion) = AsyncStream<Void>.makeStream()
        defer {
            if let observation { monitor.removeReadinessObserver(observation) }
            observation = nil
            isWaiting = false
            completion.finish()
        }
        try Task.checkCancellation()
        isWaiting = true
        observation = monitor.observeReadiness { [weak self] root in
            guard let self, expectedRoots.contains(root) else { return }
            observedRoots.insert(root)
            if isComplete { completion.finish() }
        }
        // Registration and the actual activation are one MainActor segment.
        // AsyncStream retains completion even before its iterator starts.
        trigger()
        for await _ in events { }
        try Task.checkCancellation()
        try #require(isComplete)
    }
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t333ForegroundPhaseCancellationRemovesObserverBeforeHeldBReturns() async throws {
    let f = try await RecoveryFixture()
    let started = StartedTasks()
    try await withAsyncTeardown {
        let c = f.controller(); defer { c.window?.close() }
        c.browseRecoveredFolder(f.b, rootID: f.rootB)
        try await f.ready(c, folder: f.b)
        await f.services.monitor.start()
        let roots = Set(await f.services.files.records().map(\.id))
        try #require(roots == Set([f.rootA, f.rootB]))

        let beforeEntry = RecoveryForegroundPhase(monitor: f.services.monitor, roots: roots)
        let alreadyCancelled = Task { @MainActor in try await beforeEntry.run() }
        alreadyCancelled.cancel()
        do { try await alreadyCancelled.value; Issue.record("Cancelled phase unexpectedly succeeded") }
        catch is CancellationError { }
        #expect(!beforeEntry.hasObserver && !beforeEntry.isWaiting && beforeEntry.observedRoots.isEmpty)

        await f.mounts.pauseEnumeration(after: 1)
        let phase = RecoveryForegroundPhase(monitor: f.services.monitor, roots: roots)
        let waiter = started.track(Task { @MainActor in try await phase.run() })
        defer { waiter.cancel() }
        try await f.mounts.waitUntilPaused()
        #expect(await f.mounts.paused)
        #expect(phase.hasObserver && phase.isWaiting && !phase.isComplete)
        #expect(phase.observedRoots == Set([f.rootA]))
        waiter.cancel()
        do { try await waiter.value; Issue.record("Pending phase unexpectedly succeeded after cancellation") }
        catch is CancellationError { }
        #expect(!phase.hasObserver && !phase.isWaiting && !phase.isComplete)
        #expect(phase.observedRoots == Set([f.rootA]))
        #expect(await f.mounts.paused)
        print("i333 cancellation: before-entry and held-B waiters exited with CancellationError and no observer")

        // Subscribe before releasing B. Its late readiness must not reach the
        // cancelled phase, and the continuing foreground job must finish cleanup.
        let drain = RecoveryForegroundPhase(monitor: f.services.monitor, roots: Set([f.rootB]))
        try await drain.run { Task { await f.mounts.release() } }
        #expect(drain.isComplete && drain.observedRoots == Set([f.rootB]))
        #expect(phase.observedRoots == Set([f.rootA]) && !phase.hasObserver)
        #expect(!(await f.mounts.paused))
        print("i333 cancellation: held B released and real foreground drained without resuming cancelled waiter")
    } teardown: {
        started.cancelAll()
        await started.awaitAll { await f.mounts.release() }
        f.remove(); await f.mounts.release()
    }
}


private func t231Fix2AppRecordedRoot(_ item: RecentFolder) throws -> String? {
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    return object["recordedRoot"] as? String
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t231Fix2ProductionRecentRecordingSurvivesOverlappingInactiveMoves() async throws {
    let f = try await RecoveryFixture(aComponents: ["container", "album"]); defer { f.remove() }
    let c = f.controller(); defer { c.window?.close() }
    c.browseRecoveredFolder(f.childOne, rootID: f.rootA)
    try await f.ready(c, folder: f.childOne, count: 2)
    try await c.rememberFolder(f.childOne, rootID: f.rootA)
    let recorded = try #require(try await f.services.recent.load().first { $0.rootID == f.rootA })
    #expect(try t231Fix2AppRecordedRoot(recorded) == f.a.absoluteString)
    c.browseRecoveredFolder(f.b, rootID: f.rootB)
    try await f.ready(c, folder: f.b)
    let started = StartedTasks()
    try await withAsyncTeardown {
        await f.services.monitor.start()
        let roots = Set(await f.services.files.records().map(\.id))
        try #require(roots == Set([f.rootA, f.rootB]))
        let staging = f.base.appendingPathComponent("staging", isDirectory: true)
        let container = f.a.deletingLastPathComponent()
        let first = RecoveryForegroundPhase(monitor: f.services.monitor, roots: roots)
        var secondMoveStarted = false
        await f.mounts.pauseEnumeration(after: 1)
        try await f.moveRoot(to: staging)
        let checker = Task { @MainActor in
            try await f.mounts.waitUntilPaused()
            #expect(await f.mounts.paused)
            #expect(first.hasObserver && first.isWaiting && !first.isComplete)
            #expect(first.observedRoots == Set([f.rootA]))
            #expect(!secondMoveStarted)
            #expect(await f.services.files.rootURL(f.rootA)?.path == staging.path)
            #expect(FileManager.default.fileExists(atPath: staging.path))
            #expect(!FileManager.default.fileExists(atPath: f.a.path))
            print("i333 fix1 GREEN: held B; first foreground registered and pending with only A ready; move two blocked")
            await f.mounts.release()
        }
        started.track(checker)
        defer { checker.cancel() }
        try await first.run()
        try await checker.value
        #expect(first.observedRoots == roots && first.isComplete && !first.hasObserver)
        #expect(await f.services.files.rootURL(f.rootA)?.path == staging.path)
        print("i333 fix1 GREEN: first foreground completed all roots before move two")
        secondMoveStarted = true
        try await f.services.files.runIsolated {
            try FileManager.default.removeItem(at: container)
            try FileManager.default.moveItem(at: staging, to: container)
            f.bookmarks.relocate(staging, to: container)
        }
        let second = RecoveryForegroundPhase(monitor: f.services.monitor, roots: roots)
        try await second.run()
        #expect(second.observedRoots == roots && second.isComplete && !second.hasObserver)
        #expect(await f.services.files.rootURL(f.rootA)?.path == container.path)
        print("i333 fix1 GREEN: fresh second foreground completed all roots at container")
        #expect(c.session.folderScan?.snapshot?.version.rootID == f.rootB)
        #expect(try await f.services.recent.load().contains(recorded))
        let replacement = f.base.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.copyItem(at: container, to: replacement)
        try FileManager.default.createDirectory(at: replacement.appendingPathComponent("album/One"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: container)
        f.bookmarks.fail(container, true)
        c.openRecent(recorded)
        try await recoveryWait { c.waitingAccessPosition?.rootID == f.rootA && recoveryPage(c) != nil }
        // Reconnection first renders an unknown cause, then classifies the root asynchronously.
        try await recoveryWait { c.accessLossCause == .notFound }
        f.gate.arm(replacement)
        defer { f.gate.release() }
        await f.mounts.pauseEnumeration()
        c.completeAccessFolderSelection(replacement, reselect: true)
        try await recoveryWaitAsync { await f.mounts.paused }
        // The next mount query can belong to an outstanding foreground check.
        // Observe FileAccess transaction publication before inspecting committed bytes.
        try await recoveryWaitAsync {
            let records = await f.services.files.records()
            return !records.contains { $0.id == f.rootA } && records.contains { $0.id != f.rootB }
        }
        let committed = try await f.services.recent.load()
        let mapped = committed.filter { $0.displayName == recorded.displayName }
        #expect(mapped.count == 1)
        #expect(mapped.first?.url.path == replacement.appendingPathComponent("One").path)
        #expect(!mapped.contains { $0.url.path == replacement.appendingPathComponent("album/One").path })
        if let item = mapped.first { #expect(try t231Fix2AppRecordedRoot(item) == replacement.absoluteString) }
        f.gate.release()
        await f.mounts.release()
        try await f.ready(c, folder: replacement)
    } teardown: {
        started.cancelAll()
        await started.awaitAll { await f.mounts.release() }
    }
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t231Fix2ServiceRecordingPathsPersistCurrentRootProvenance() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let granted = f.base.appendingPathComponent("Granted", isDirectory: true)
    let selected = f.base.appendingPathComponent("Selected", isDirectory: true)
    let moved = f.base.appendingPathComponent("Moved", isDirectory: true)
    for url in [granted, selected] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let grantID = try await f.services.grant(granted)
    let grantRecent = try #require(try await RecentFolderStore(url: f.base.appendingPathComponent("recent.json")).load().first { $0.rootID == grantID })
    #expect(try t231Fix2AppRecordedRoot(grantRecent) == granted.absoluteString)
    try await f.moveRoot(to: moved)
    let reconnected = try await f.services.reconnect(f.rootA, folder: moved)
    #expect(reconnected.rootID == f.rootA)
    let reconnectRecent = try #require(try await RecentFolderStore(url: f.base.appendingPathComponent("recent.json")).load().first { $0.rootID == f.rootA })
    #expect(try t231Fix2AppRecordedRoot(reconnectRecent) == moved.absoluteString)
    let reselected = try await f.services.reselect(f.rootA, folder: selected, reference: nil)
    #expect(!reselected.restored && reselected.rootID != f.rootA)
    let selectRecent = try #require(try await RecentFolderStore(url: f.base.appendingPathComponent("recent.json")).load().first { $0.rootID == reselected.rootID })
    #expect(try t231Fix2AppRecordedRoot(selectRecent) == selected.absoluteString)
}


@MainActor @Test(.timeLimit(.minutes(3)))
func t231Fix2MatchingReselectRefreshesRecordedRootProvenance() async throws {
    let f = try await RecoveryFixture(); defer { f.remove() }
    let reference = try #require(try await f.services.files.captureRecoveryFolder(rootID: f.rootA, folder: f.childOne))
    let moved = f.base.appendingPathComponent("MatchedMove", isDirectory: true)
    try await f.moveRoot(to: moved)
    let selected = try await f.services.reselect(f.rootA, folder: moved, reference: reference)
    #expect(selected.restored && selected.rootID == f.rootA)
    let recent = try #require(try await RecentFolderStore(url: f.base.appendingPathComponent("recent.json")).load().first { $0.rootID == f.rootA })
    #expect(try t231Fix2AppRecordedRoot(recent) == moved.absoluteString)
}
