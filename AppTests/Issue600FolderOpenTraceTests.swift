import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

final class FolderOpen600Events: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [FolderOpenStageEvent] = []
    func append(_ event: FolderOpenStageEvent) { lock.withLock { captured.append(event) } }
    var events: [FolderOpenStageEvent] { lock.withLock { captured } }
    func report() -> String {
        let events = events
        let completed = events.last { $0.outcome == .completed }?.stage ?? "none"
        return "lastCompleted=\(completed); " + events.map(\.description).joined(separator: ", ")
    }
}

private actor FolderOpen600Signal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor private final class FolderOpen600Gate {
    let entered = FolderOpen600Signal()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await entered.signal()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

@MainActor private final class FolderOpen600Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private struct FolderOpen600Rig {
    let base: URL
    let folder: URL
    let services: AccessServices
    init() throws {
        _ = NSApplication.shared
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("trace600-\(UUID())", isDirectory: true)
        folder = base.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: asset)
        for index in 0..<3 { try data.write(to: folder.appendingPathComponent("\(index).png")) }
        let system = SystemSecurityScope()
        let files = try FileAccess(scope: system, bookmarks: system,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue600")
        services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    }
    func controller(servicesTask: Task<AccessServices, any Error>? = nil) -> CanvasWindowController {
        CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: servicesTask ?? Task { services }, motionPolicy: MotionPolicy(source: FolderOpen600Motion()))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

@MainActor private func wait600(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

@Test @MainActor
func issue600RejectedOpenReportsCompletedGrantAndReason() async throws {
    let rig = try FolderOpen600Rig()
    defer { rig.remove() }
    let controller = rig.controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let captured = FolderOpen600Events()
    controller.folderOpenStageObserver = { [weak window] event in
        captured.append(event)
        if event.stage == "grant", event.outcome == .completed {
            MainActor.assumeIsolated { window?.close() }
        }
    }
    controller.openGrantedFolder(rig.folder)
    try await wait600 { captured.events.contains { $0.outcome == .rejected } }
    let events = captured.events
    #expect(events.contains { $0.stage == "fileAccess.grant" && $0.outcome == .completed }, "\(captured.report())")
    #expect(events.contains { $0.stage == "monitor.reauthorize" && $0.outcome == .completed }, "\(captured.report())")
    #expect(events.contains { $0.stage == "recents" && $0.outcome == .completed }, "\(captured.report())")
    #expect(events.last { $0.outcome == .completed }?.stage == "grant", "\(captured.report())")
    #expect(events.last?.outcome == .rejected, "\(captured.report())")
    #expect(events.last?.reason == "task-cancelled", "\(captured.report())")
    #expect(!events.contains { $0.stage == "openFolder" || $0.stage == "coordinator.begin" }, "\(captured.report())")
    #expect(controller.session.folderScan == nil)
    #expect(try await rig.services.recent.load().first?.url == rig.folder)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SuccessfulTraceIsOrderedAndDefaultStillScans() async throws {
    var results: [Set<String>] = []
    for recording in [true, false] {
        let rig = try FolderOpen600Rig()
        defer { rig.remove() }
        let controller = rig.controller()
        let window = try #require(controller.window)
        defer { window.close() }
        let captured = FolderOpen600Events()
        let recovered = FolderOpen600Signal()
        if recording {
            controller.folderOpenStageObserver = { event in
                captured.append(event)
                if event.stage == "recovery", event.outcome == .completed {
                    Task { await recovered.signal() }
                }
            }
        }
        let before = ContinuousClock.now
        controller.openGrantedFolder(rig.folder)
        if recording { try await wait600Signal(recovered) }
        try await wait600 { controller.gridSearchAvailable && controller.session.folderScan?.sourceSnapshot?.isComplete == true }
        let after = ContinuousClock.now
        let scan = controller.session.folderScan
        #expect(scan?.sourceSnapshot?.isComplete == true, "\(captured.report())")
        #expect(controller.gridSearchAvailable, "\(captured.report())")
        results.append(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []))
        #expect(try await rig.services.recent.load().first?.url == rig.folder)
        let events = captured.events
        if recording {
            let completed = events.filter { $0.outcome == .completed }.map(\.stage)
            let milestones = ["services", "fileAccess.grant", "monitor.reauthorize", "recents", "grant",
                "scan.services", "readContext", "coordinator.begin", "coordinator.task", "recovery"]
            var position = 0
            for stage in completed where position < milestones.count {
                if stage == milestones[position] { position += 1 }
            }
            #expect(position == milestones.count, "\(captured.report())")
            #expect(events.contains { $0.stage == "openFolder" && $0.outcome == .entered })
            #expect(!events.contains { $0.outcome == .rejected }, "\(captured.report())")
            #expect(Set(events.map(\.openingID)).count == 1)
            #expect(events.allSatisfy { before <= $0.instant && $0.instant <= after })
            #expect(zip(events, events.dropFirst()).allSatisfy { $0.instant <= $1.instant })
        } else { #expect(events.isEmpty) }
    }
    #expect(results == [Set(["0.png", "1.png", "2.png"]), Set(["0.png", "1.png", "2.png"])])
}

@Test @MainActor
func issue600SupersededOpeningKeepsItsCapturedObserver() async throws {
    let rig = try FolderOpen600Rig()
    defer { rig.remove() }
    let second = rig.base.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: rig.folder.appendingPathComponent("0.png"), to: second.appendingPathComponent("second.png"))
    var release: CheckedContinuation<AccessServices, Never>?
    let servicesTask = Task<AccessServices, any Error> { await withCheckedContinuation { release = $0 } }
    let controller = rig.controller(servicesTask: servicesTask)
    let window = try #require(controller.window)
    defer { window.close() }
    let firstEvents = FolderOpen600Events(), secondEvents = FolderOpen600Events()
    controller.folderOpenStageObserver = { firstEvents.append($0) }
    controller.openGrantedFolder(rig.folder)
    try await wait600 { firstEvents.events.contains { $0.stage == "services" && $0.outcome == .entered } && release != nil }
    controller.folderOpenStageObserver = { secondEvents.append($0) }
    controller.openGrantedFolder(second)
    try await wait600 { secondEvents.events.contains { $0.stage == "services" && $0.outcome == .entered } }
    release?.resume(returning: rig.services)
    try await wait600 {
        controller.gridSearchAvailable && controller.session.folderScan?.sourceSnapshot?.isComplete == true &&
            firstEvents.events.contains { $0.outcome == .rejected }
    }
    let first = firstEvents.events, latest = secondEvents.events
    #expect(first.last?.outcome == .rejected, "\(firstEvents.report())")
    #expect(first.last?.reason == "task-cancelled", "\(firstEvents.report())")
    #expect(!first.contains { $0.stage == "openFolder" || $0.stage == "coordinator.begin" })
    #expect(Set(first.map(\.openingID)).count == 1)
    #expect(Set(latest.map(\.openingID)).count == 1)
    #expect(first.first?.openingID != latest.first?.openingID)
    #expect(!latest.contains { $0.outcome == .rejected }, "\(secondEvents.report())")
    #expect(latest.contains { $0.stage == "coordinator.begin" && $0.outcome == .completed }, "\(secondEvents.report())")
    #expect(Set(controller.session.folderScan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["second.png"]))
    #expect(try await rig.services.recent.load().first?.url == second)
}

// #600: the scheduling gate delays optional metadata without blocking FileAccess's
// actor. Gate entry is the deterministic observation point: the real initial
// scan must already have completed, with no polling or sleep to induce the stall.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue600HeldRecoveryCaptureStillCompletesInitialGrid() async throws {
    let rig = try FolderOpen600Rig()
    defer { rig.remove() }
    let link = rig.base.appendingPathComponent("selected-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.folder)
    let controller = rig.controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let gate = FolderOpen600Gate()
    defer { gate.release() }
    let settled = FolderOpen600Signal()
    controller.recoveryCaptureWillBegin = { _ in await gate.hold() }
    controller.folderOpenStageObserver = { event in
        if event.stage == "recovery", event.outcome == .completed { Task { await settled.signal() } }
    }
    controller.openGrantedFolder(link)
    try await wait600Signal(gate.entered)
    let scan = controller.session.folderScan
    #expect(scan?.sourceSnapshot?.isComplete == true)
    #expect(scan?.isScanning == false)
    #expect(controller.gridSearchAvailable)
    #expect(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
    #expect(window.title == "selected-link")
    #expect(try await rig.services.recent.load().first?.url == rig.folder)
    #expect(controller.folderRecoveryReference == nil)
    gate.release()
    try await wait600Signal(settled)
    #expect(controller.folderRecoveryReference?.folderURL == rig.folder)
    #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == true)
    #expect(controller.gridSearchAvailable)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600SupersededRecoveryCannotPublishOldFolder() async throws {
    let rig = try FolderOpen600Rig()
    defer { rig.remove() }
    let second = rig.base.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: rig.folder.appendingPathComponent("0.png"), to: second.appendingPathComponent("second.png"))
    let controller = rig.controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let gate = FolderOpen600Gate()
    defer { gate.release() }
    let oldSettled = FolderOpen600Signal(), latestSettled = FolderOpen600Signal()
    controller.recoveryCaptureWillBegin = { _ in await gate.hold() }
    controller.folderOpenStageObserver = { event in
        if event.stage == "recovery", event.outcome == .completed { Task { await oldSettled.signal() } }
    }
    controller.openGrantedFolder(rig.folder)
    try await wait600Signal(gate.entered)
    controller.recoveryCaptureWillBegin = nil
    controller.folderOpenStageObserver = { event in
        if event.stage == "recovery", event.outcome == .completed { Task { await latestSettled.signal() } }
    }
    controller.openGrantedFolder(second)
    try await wait600Signal(latestSettled)
    let latestReference = controller.folderRecoveryReference
    #expect(latestReference?.folderURL == second)
    #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == true)
    gate.release()
    try await wait600Signal(oldSettled)
    #expect(controller.folderRecoveryReference?.rootID == latestReference?.rootID)
    #expect(controller.folderRecoveryReference?.folderURL == latestReference?.folderURL)
    #expect(controller.folderRecoveryReference?.folderIdentity == latestReference?.folderIdentity)
    #expect(controller.session.folderScan?.sourceSnapshot?.version.folder == second)
    #expect(controller.session.folderScan?.isScanning == false)
    #expect(Set(controller.session.folderScan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["second.png"]))
    #expect(controller.gridSearchAvailable)
    #expect(window.title == "second")
    #expect(try await rig.services.recent.load().first?.url == second)
    let root = try #require(latestReference?.rootID)
    rig.services.monitor.restoreLostRoot(root, volumeUUID: nil, cause: .notFound)
    #expect(controller.waitingAccessPosition?.folderReference?.rootID == latestReference?.rootID)
    #expect(controller.waitingAccessPosition?.folderReference?.folderURL == latestReference?.folderURL)
    #expect(controller.waitingAccessPosition?.folderReference?.folderIdentity == latestReference?.folderIdentity)
    #expect(controller.waitingAccessPosition?.folderURL == second)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600ClosedWindowRejectsDelayedRecoveryPublication() async throws {
    let rig = try FolderOpen600Rig()
    defer { rig.remove() }
    let controller = rig.controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let gate = FolderOpen600Gate()
    defer { gate.release() }
    let settled = FolderOpen600Signal()
    controller.recoveryCaptureWillBegin = { _ in await gate.hold() }
    controller.folderOpenStageObserver = { event in
        if event.stage == "recovery", event.outcome == .completed { Task { await settled.signal() } }
    }
    controller.openGrantedFolder(rig.folder)
    try await wait600Signal(gate.entered)
    #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == true)
    let grid = try grid600(controller)
    window.close()
    gate.release()
    try await wait600Signal(settled)
    #expect(!window.isVisible)
    // Base 58df8a93 retains the stopped coordinator and derived search flag.
    // Assert the rendered presentation is revoked rather than object disposal.
    #expect(controller.session.folderScan?.isScanning == false)
    #expect(grid.displayedItemIDs.isEmpty)
    #expect(grid.window?.isVisible != true)
    #expect(controller.waitingAccessPosition == nil)
    #expect(controller.folderRecoveryReference == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600AccessLossRejectsDelayedRecoveryPublication() async throws {
    let rig = try FolderOpen600Rig()
    defer { rig.remove() }
    let controller = rig.controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let gate = FolderOpen600Gate()
    defer { gate.release() }
    let settled = FolderOpen600Signal()
    controller.recoveryCaptureWillBegin = { _ in await gate.hold() }
    controller.folderOpenStageObserver = { event in
        if event.stage == "recovery", event.outcome == .completed { Task { await settled.signal() } }
    }
    controller.openGrantedFolder(rig.folder)
    try await wait600Signal(gate.entered)
    #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == true)
    let root = try #require(await rig.services.files.records().first?.id)
    rig.services.monitor.restoreLostRoot(root, volumeUUID: nil, cause: .notFound)
    let counter = controller.waitingAccessPosition?.counter
    #expect(controller.waitingAccessPosition?.folderURL == rig.folder)
    #expect(controller.waitingAccessPosition?.folderReference == nil)
    gate.release()
    try await wait600Signal(settled)
    #expect(controller.waitingAccessPosition?.rootID == root)
    #expect(controller.waitingAccessPosition?.counter == counter)
    #expect(controller.waitingAccessPosition?.folderReference == nil)
    #expect(controller.folderRecoveryReference == nil)
    // Base 58df8a93 keeps the coordinator while revoking visible content.
    #expect(controller.session.folderScan?.isScanning == false)
    #expect(try grid600(controller).displayedItemIDs.isEmpty)
    #expect(!controller.gridSearchAvailable)
}

@MainActor private func grid600(_ controller: CanvasWindowController) throws -> GridBrowserView {
    let shell = try #require(controller.window?.contentView?.subviews.compactMap { $0 as? GridShellView }.first)
    return try #require(shell.mainContent.subviews.compactMap { $0 as? GridBrowserView }.first)
}

/// The OS bookmark resolver is the only controlled boundary: actual native
/// bookmark data/identity is retained, while rename visibility is atomic with
/// the FileAccess turn. Native #507 cases cover normal unwrapped grants/scans.
private final class Moving600Bookmarks: BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private let system = SystemSecurityScope()
    private var locations: [Data: URL] = [:]
    var requiresEmbeddedIdentity: Bool { system.requiresEmbeddedIdentity }
    func create(for url: URL) throws -> Data {
        let data = try system.create(for: url)
        lock.withLock { locations[data] = url }
        return data
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if let url = lock.withLock({ locations[data] }) { return ResolvedBookmark(url: url, stale: false) }
        return try system.resolve(data)
    }
    func relocate(_ source: URL, to target: URL) {
        lock.withLock {
            for (data, url) in locations where path600(url) == path600(source) { locations[data] = target }
        }
    }
}

@MainActor private struct Moving600Rig {
    let base: URL, folder: URL
    let bookmarks = Moving600Bookmarks()
    let services: AccessServices
    init() throws {
        let fixture = try FolderOpen600Rig()
        base = fixture.base; folder = fixture.folder
        let system = SystemSecurityScope()
        let files = try FileAccess(scope: system, bookmarks: bookmarks,
            store: BookmarkStore(url: base.appendingPathComponent("moving-roots.json")), buildSHA: "issue600-moving")
        services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("moving-recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    }
    func controller() -> CanvasWindowController {
        CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: FolderOpen600Motion()))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

extension FileAccess {
    /// No lease can resolve the old bookmark location between rename and relocation.
    fileprivate func issue600MoveFolder(from source: URL, to target: URL, bookmarks: Moving600Bookmarks) throws {
        try FileManager.default.moveItem(at: source, to: target)
        bookmarks.relocate(source, to: target)
    }
}

private func wait600Signal(_ signal: FolderOpen600Signal) async throws {
    try await withTaskCancellationHandler {
        await signal.wait()
        try Task.checkCancellation()
    } onCancel: {
        Task { await signal.signal() }
    }
}

private func path600(_ url: URL?) -> [String]? {
    url?.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600WatchedMoveRejectsOriginalDelayedRecovery() async throws {
    let rig = try Moving600Rig()
    defer { rig.remove() }
    let moved = rig.folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        .deletingLastPathComponent().appendingPathComponent("Moved", isDirectory: true)
    let controller = rig.controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let initial = FolderOpen600Gate(), following = FolderOpen600Gate()
    defer { initial.release(); following.release() }
    let settled = FolderOpen600Signal(), captured = FolderOpen600Events()
    let originalPath = path600(rig.folder), movedPath = path600(moved)
    var initialEntered = false, followingEntered = false
    controller.recoveryCaptureWillBegin = { folder in
        if path600(folder) == originalPath {
            initialEntered = true
            await initial.hold()
        } else if path600(folder) == movedPath {
            followingEntered = true
            await following.hold()
        }
    }
    controller.folderOpenStageObserver = { event in
        captured.append(event)
        if event.stage == "recovery", event.outcome == .completed { Task { await settled.signal() } }
    }
    controller.openGrantedFolder(rig.folder)
    try await wait600 { initialEntered }
    try #require(initialEntered, "Initial capture gate: \(captured.report())")
    let originalScan = try #require(controller.session.folderScan)
    let root = try #require(await rig.services.files.records().first?.id)
    #expect(originalScan.sourceSnapshot?.isComplete == true)
    try await rig.services.files.issue600MoveFolder(from: rig.folder, to: moved, bookmarks: rig.bookmarks)
    let watch = try #require(rig.services.watch as? WatchHub)
    watch.reconcileAll()
    try await wait600 { followingEntered }
    let movedDiagnostic = "following=\(followingEntered); snapshot=\(String(describing: controller.session.folderScan?.sourceSnapshot?.version.folder)); failure=\(String(describing: controller.session.folderScan?.failure)); waiting=\(String(describing: controller.waitingAccessPosition?.folderURL)); stages=\(captured.report())"
    try #require(followingEntered, "\(movedDiagnostic)")
    following.release()
    try await wait600 { path600(controller.folderRecoveryReference?.folderURL) == movedPath }
    let movedReference = try #require(controller.folderRecoveryReference)
    #expect(movedReference.rootID == root)
    #expect(path600(movedReference.folderURL) == movedPath)
    #expect(controller.session.folderScan === originalScan)
    #expect(path600(controller.session.folderScan?.sourceSnapshot?.version.folder) == movedPath)
    #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == true)
    #expect(controller.session.folderScan?.isScanning == false)
    #expect(Set(controller.session.folderScan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
    #expect(controller.gridSearchAvailable)
    #expect(path600(window.representedURL) == movedPath)
    #expect(await rig.services.files.records().count == 1)
    initial.release()
    try await wait600Signal(settled)
    #expect(controller.folderRecoveryReference?.rootID == root)
    #expect(path600(controller.folderRecoveryReference?.folderURL) == movedPath)
    #expect(controller.folderRecoveryReference?.folderIdentity == movedReference.folderIdentity)
    #expect(path600(controller.session.folderScan?.sourceSnapshot?.version.folder) == movedPath)
    #expect(controller.gridSearchAvailable)
    rig.services.monitor.restoreLostRoot(root, volumeUUID: nil, cause: .notFound)
    #expect(path600(controller.waitingAccessPosition?.folderURL) == movedPath)
    #expect(controller.waitingAccessPosition?.folderReference?.rootID == root)
    #expect(path600(controller.waitingAccessPosition?.folderReference?.folderURL) == movedPath)
    #expect(controller.waitingAccessPosition?.folderReference?.folderIdentity == movedReference.folderIdentity)
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600AuthorizedOpeningCapturesRecoveryBeforeGridReadiness() async throws {
    for recording in [false, true] {
        let rig = try FolderOpen600Rig()
        defer { rig.remove() }
        let root = try await rig.services.grant(rig.folder)
        let controller = rig.controller()
        let window = try #require(controller.window)
        defer { window.close() }
        let gate = FolderOpen600Gate()
        defer { gate.release() }
        controller.recoveryCaptureWillBegin = { _ in await gate.hold() }
        if recording {
            let events = FolderOpen600Events()
            controller.folderOpenStageObserver = { events.append($0) }
        }
        controller.browseRecoveredFolder(rig.folder, rootID: root)
        try await wait600Signal(gate.entered)
        #expect(controller.session.folderScan?.sourceSnapshot?.isComplete != true)
        #expect(!controller.gridSearchAvailable)
        #expect(controller.folderRecoveryReference == nil)
        gate.release()
        try await wait600 { controller.session.folderScan?.sourceSnapshot?.isComplete == true && controller.gridSearchAvailable }
        #expect(controller.session.folderScan?.sourceSnapshot?.isComplete == true)
        #expect(controller.folderRecoveryReference?.folderURL == rig.folder)
        #expect(controller.folderRecoveryReference?.rootID == root)
        #expect(Set(controller.session.folderScan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
    }
}

private func assert600DiagnosticSpans(_ events: [FolderOpenStageEvent]) {
    let spans = Dictionary(grouping: events.filter { $0.kind == .synchronous }, by: { $0.spanID })
    #expect(!spans.isEmpty)
    for (_, span) in spans {
        #expect(span.first?.spanID != nil)
        #expect(span.filter { $0.outcome == .entered }.count == 1)
        #expect(span.filter { $0.outcome == .completed || $0.outcome == .rejected }.count == 1)
        if let first = span.first, let last = span.last { #expect(first.instant <= last.instant) }
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600DiagnosticJobsAndSynchronousSpansPreserveOutput() async throws {
    var results: [Set<String>] = []
    for observing in [false, true] {
        let rig = try FolderOpen600Rig(); defer { rig.remove() }
        let captured = FolderOpen600Events()
        let observer: (@Sendable (FolderOpenStageEvent) -> Void)? = observing ? { @Sendable event in captured.append(event) } : nil
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { rig.services }, motionPolicy: MotionPolicy(source: FolderOpen600Motion()),
            folderOpenDiagnosticObserver: observer)
        let window = try #require(controller.window); defer { window.close() }
        controller.openGrantedFolder(rig.folder)
        try await wait600 { controller.gridSearchAvailable && controller.session.folderScan?.sourceSnapshot?.isComplete == true && controller.session.folderScan?.isScanning == false }
        let scan = controller.session.folderScan
        #expect(scan?.sourceSnapshot?.isComplete == true)
        #expect(scan?.isScanning == false)
        #expect(controller.gridSearchAvailable)
        #expect(window.title == rig.folder.lastPathComponent)
        #expect(window.attachedSheet == nil)
        #expect(try await rig.services.recent.load().first?.url == rig.folder)
        results.append(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []))
        window.close()
        let events = captured.events.sorted { $0.instant < $1.instant }
        if observing {
            for stage in ["scan.task", "recents.task", "sidebar.task", "accessAttachment.task"] {
                let queued = events.filter { $0.kind == .job && $0.stage == stage && $0.outcome == .queued }
                #expect(!queued.isEmpty, "Missing queued job \(stage)")
                for entry in queued {
                    #expect(entry.jobID != nil)
                    let started = events.first { $0.kind == .job && $0.jobID == entry.jobID && $0.outcome == .entered }
                    #expect(started != nil)
                    if let started { #expect(entry.instant <= started.instant) }
                }
            }
            assert600DiagnosticSpans(events)
            #expect(Set(events.map(\.controllerID)).count == 1)
            #expect(events.filter { $0.kind == .synchronous }.allSatisfy { $0.isMainThread })
        } else { #expect(events.isEmpty) }
    }
    #expect(results == [Set(["0.png", "1.png", "2.png"]), Set(["0.png", "1.png", "2.png"])])
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue600DiagnosticPriorControllerWaitKeepsCapturedAttribution() async throws {
    let firstRig = try FolderOpen600Rig(), latestRig = try FolderOpen600Rig()
    defer { firstRig.remove(); latestRig.remove() }
    let shared = FolderOpen600Events(), replaced = FolderOpen600Events()
    var release: CheckedContinuation<AccessServices, Never>?
    let services = Task<AccessServices, any Error> { await withCheckedContinuation { release = $0 } }
    let first = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: services, motionPolicy: MotionPolicy(source: FolderOpen600Motion()),
        folderOpenDiagnosticObserver: { shared.append($0) })
    let firstWindow = try #require(first.window); defer { firstWindow.close(); release?.resume(returning: firstRig.services); release = nil }
    try await wait600 { release != nil && shared.events.contains { $0.kind == .wait && $0.outcome == .entered } }
    #expect(release != nil)
    let firstIDs = Set(shared.events.map(\.controllerID))
    #expect(firstIDs.count == 1)
    let pending = shared.events
    let openSync = Dictionary(grouping: pending.filter { $0.kind == .synchronous }, by: { $0.spanID })
    #expect(openSync.values.allSatisfy { span in span.filter { $0.outcome == .entered }.count == span.filter { $0.outcome == .completed || $0.outcome == .rejected }.count })
    first.folderOpenStageObserver = { replaced.append($0) }
    firstWindow.close()
    let latest = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { latestRig.services }, motionPolicy: MotionPolicy(source: FolderOpen600Motion()),
        folderOpenDiagnosticObserver: { shared.append($0) })
    let latestWindow = try #require(latest.window); defer { latestWindow.close() }
    latest.openGrantedFolder(latestRig.folder)
    try await wait600 { latest.gridSearchAvailable && latest.session.folderScan?.sourceSnapshot?.isComplete == true }
    release?.resume(returning: firstRig.services); release = nil
    try await wait600 { shared.events.contains { firstIDs.contains($0.controllerID) && $0.kind == .job && $0.stage == "accessAttachment.task" && $0.outcome == .completed } }
    #expect(!firstWindow.isVisible)
    #expect(first.folderRecoveryReference == nil)
    #expect(latest.gridSearchAvailable)
    #expect(Set(latest.session.folderScan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == Set(["0.png", "1.png", "2.png"]))
    #expect(latestWindow.title == latestRig.folder.lastPathComponent)
    #expect(replaced.events.isEmpty)
    #expect(Set(shared.events.map(\.controllerID)).count == 2)
    #expect(shared.events.contains { firstIDs.contains($0.controllerID) && $0.kind == .job && $0.outcome == .completed })
    assert600DiagnosticSpans(shared.events)
}
