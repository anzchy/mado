import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class SidebarMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func sidebarTree(_ controller: CanvasWindowController) throws -> GridSidebarTreeView {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let content = try #require(controller.window?.contentView)
    return try #require(descendants(content)
        .compactMap { $0 as? GridSidebarTreeView }.first)
}

@MainActor private func sidebarCancelButton(_ controller: CanvasWindowController) throws -> NSButton {
    func buttons(_ view: NSView) -> [NSButton] {
        let current: [NSButton] = (view as? NSButton).map { [$0] } ?? []
        return current + view.subviews.flatMap(buttons)
    }
    let content = try #require(controller.window?.contentView)
    return try #require(buttons(content).first { $0.title == String(localized: "Cancel Reading") })
}
private func sameSidebarURL(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
}

/// `impossible` gives a deterministic reason the stage can no longer complete, read from an injected fake's state and
/// never from elapsed time; the stage then fails at once (#400, #751). It does not bound a live wait: on the re-arming
/// handoff gates `spent` never holds, so there it only guards the fixture against a regression of the re-arm.
@MainActor private func waitForSidebar(_ stage: String, refreshing watch: (any FolderWatching)? = nil,
    state: () -> String = { "" }, impossible: () -> String? = { nil },
    fileID: String = #fileID, line: Int = #line, _ condition: () async -> Bool) async throws {
    watch?.reconcileAll()
    var blocked: String?
    do { try await waitUntil("sidebar stage: \(stage)", fileID: fileID, line: line) {
        if await condition() { return true }
        blocked = impossible(); return blocked != nil
    } } catch { throw sidebarStageFailure(stage, error, state: state()) }
    guard let blocked else { return }
    throw sidebarStageFailure(stage, ConditionWaitError(description:
        "sidebar stage \(stage) can never complete at \(fileID):\(line): \(blocked)"), state: state())
}

/// Prints the failed stage on stdout, so CI's uploaded first-attempt log names it and the state it saw (#425).
@MainActor private func sidebarStageFailure(_ stage: String, _ error: any Error, state seen: String) -> any Error {
    guard !seen.isEmpty else { print("sidebar stage \(stage) failed: \(error)"); return error }
    print("sidebar stage \(stage) failed; state: \(seen)")
    return ConditionWaitError(description: "\(error); state: \(seen)")
}

/// Holds the first caller after `arm()` until the test calls `release()`. A caller whose task is already cancelled
/// never claims the arm. A holder cancelled before the release is abandoned: a re-arming gate arms again so the
/// next caller holds instead (#751); any other gate is then spent.
final class SidebarHandoffGate: @unchecked Sendable {
    private final class Claim: @unchecked Sendable { var id = 0 }
    private let lock = NSLock()
    private let rearmsAbandonedHold: Bool
    private var armed = false, released = false, holder = 0, holders = 0, abandoned = 0, tag = ""
    private var continuation: CheckedContinuation<Void, Never>?
    init(rearmsAbandonedHold: Bool = false) { self.rearmsAbandonedHold = rearmsAbandonedHold }
    var isArmed: Bool { lock.withLock { armed } }
    var isHolding: Bool { lock.withLock { holder != 0 } }
    /// The tag the current holder passed, or nil when nothing holds.
    var holderTag: String? { lock.withLock { holder != 0 ? tag : nil } }
    var abandonedHolds: Int { lock.withLock { abandoned } }
    /// Why no caller can hold before the test arms it again, or nil while one still can.
    var spent: String? {
        lock.withLock { armed || holder != 0 || released || abandoned == 0 ? nil :
            "its holder was cancelled before release (\(abandoned)x) and it is no longer armed" }
    }
    var state: String { lock.withLock { "armed=\(armed) holding=\(holder != 0 ? tag : "no") released=\(released) abandoned=\(abandoned)" } }
    func arm() { lock.withLock { armed = true; released = false } }
    func holdIfArmed(_ tag: String = "held") async {
        let claim = Claim()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // The arm is claimed under the lock that cancellation takes, and never by a cancelled task, so a
                // cancel always finds its own holder and a later caller can never slip past an unclaimed arm (#751).
                let holds = lock.withLock { () -> Bool in
                    guard armed, !Task.isCancelled else { return false }
                    armed = false
                    guard !released else { return false }
                    holders += 1; holder = holders; claim.id = holders; self.tag = tag
                    self.continuation = continuation
                    return true
                }
                if !holds { continuation.resume() }
            }
        } onCancel: { resume { abandon(claim) } }
    }
    func release() { resume { released = true; holder = 0; return true } }
    /// Only the cancelled holder's own hold ends; a later holder of a re-armed gate keeps holding.
    private func abandon(_ claim: Claim) -> Bool {
        guard claim.id != 0, holder == claim.id else { return false }
        holder = 0; abandoned += 1; armed = rearmsAbandonedHold
        return true
    }
    private func resume(_ change: () -> Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard change() else { return nil }
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

/// Holds the folder scan until the test lets it go, so the scan's first complete snapshot, and the canonical sidebar
/// load that snapshot starts, land at a point the test picks (#751).
private final class SidebarHandoffScanner: FolderScanning, @unchecked Sendable {
    private let browser = FolderBrowser()
    private let gate = SidebarHandoffGate()
    init() { gate.arm() }
    /// The scan has subscribed its watch and is parked at its scan (#751).
    var isHolding: Bool { gate.isHolding }
    var state: String { "scan gate \(gate.state)" }
    func releaseScan() { gate.release() }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        await gate.holdIfArmed("scan")
        try await browser.scan(in: folder, root: root, options: options, emit: emit)
    }
}

/// When the change reaches the handoff: while the replacement registration is still held (before its load reads),
/// while the replacement's own read is held, or during that read once the old subscription has retired.
/// Each case delivers one change exactly once (#298, #751).
enum SidebarHandoffDelivery: Sendable {
    case beforeRegistrationRelease, afterOldSubscriptionRetires, duringOwnedRead
}

private final class SidebarHandoffEventSource: FolderEventSource, @unchecked Sendable {
    private struct Stream: FolderEventStream {
        let onStop: @Sendable () -> Void
        func stop() { onStop() }
    }
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable ([FolderChangeHint]) -> Void] = [:]
    var liveStreams: Int { lock.withLock { handlers.count } }
    func start(watching url: URL, onHints: @escaping @Sendable ([FolderChangeHint]) -> Void) throws -> any FolderEventStream {
        let id = UUID()
        lock.withLock { handlers[id] = onHints }
        return Stream { [self] in lock.withLock { handlers[id] = nil } }
    }
    func emit(_ hint: FolderChangeHint) {
        let callbacks = lock.withLock { Array(handlers.values) }
        for handler in callbacks { handler([hint]) }
    }
}

private final class SidebarHandoffClock: WatchScheduling, @unchecked Sendable {
    private final class Token: WatchCancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func cancel() { lock.withLock { done = true } }
        var cancelled: Bool { lock.withLock { done } }
    }
    private let lock = NSLock()
    private var pending: [(token: Token, action: @Sendable () -> Void)] = []
    var nowMilliseconds: Int { 0 }
    func schedule(afterMilliseconds: Int, _ action: @escaping @Sendable () -> Void) -> any WatchCancellable {
        let token = Token()
        lock.withLock { pending.append((token, action)) }
        return token
    }
    func fireScheduledChanges() {
        while let action = lock.withLock({ () -> (@Sendable () -> Void)? in
            pending.removeAll { $0.token.cancelled }
            return pending.isEmpty ? nil : pending.removeFirst().action
        }) { action() }
    }
}

private actor SidebarLeaseTracker: AccessLeasing {
    let root: URL
    private(set) var active = 0
    private(set) var childAcquires = 0
    init(root: URL) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease {
        active += 1
        if case .root(_, let file) = request, file.lastPathComponent == "Child" { childAcquires += 1 }
        return AccessLease(url: root, rootID: AccessRootID())
    }
    func release(_ lease: AccessLease) { active -= 1 }
}

private actor SidebarBlockedCount: SidebarFolderEnumerating {
    let child: URL
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = 0
    init(child: URL) { self.child = child }
    func children(in folder: URL, root: URL) -> [URL] { [child] }
    func imageCount(in folder: URL, root: URL) async -> Int {
        started += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return 1
    }
    func release() { released = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

private actor SwitchingSidebarCounter: SidebarFolderEnumerating {
    let a: URL, b: URL
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var bStarts = 0
    init(a: URL, b: URL) { self.a = a; self.b = b }
    func children(in folder: URL, root: URL) -> [URL] {
        folder.pathComponents == a.pathComponents ? [b] : []
    }
    func imageCount(in folder: URL, root: URL) async -> Int {
        if folder.pathComponents == a.pathComponents { return 1 }
        bStarts += 1
        let count = bStarts == 1 ? 999 : 2
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return count
    }
    func release() { released = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebarABARevisitRejectsStaleBlockedCount() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = base.appendingPathComponent("A"), b = a.appendingPathComponent("B")
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let image = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/portrait-2x3.png"))
    try image.write(to: a.appendingPathComponent("a.png"))
    try image.write(to: b.appendingPathComponent("b.png"))
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "sidebar-aba")
    let root = try await access.grant(folder: base)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    defer { controller.window?.close() }
    let counter = SwitchingSidebarCounter(a: a, b: b)
    controller.sidebarBrowserOverride = SidebarFolderBrowser(access: SidebarLeaseTracker(root: base), enumerator: counter)
    controller.browseRecoveredFolder(a, rootID: root)
    let tree = try sidebarTree(controller)
    try await waitForSidebar("A count blocked at child") {
        let started = await counter.bStarts
        return tree.rows.contains { sameSidebarURL($0.folderURL, b) } && started > 0
    }
    tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.performClick(nil)
    #expect(tree.rows.first(where: { $0.current }).map { sameSidebarURL($0.folderURL, b) } == true)
    controller.browseRecoveredFolder(a, rootID: root)
    try await waitForSidebar("A revisit") {
        let started = await counter.bStarts
        return tree.rows.first(where: { $0.current }).map { sameSidebarURL($0.folderURL, a) } == true &&
            started >= 2
    }
    await counter.release()
    try await waitForSidebar("current A direct count") {
        tree.rows.first(where: { $0.current })?.countLabel.stringValue == "1" &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.countLabel.stringValue == "2"
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebarCloseCancelsBlockedCountAndTakesNoChildLease() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "sidebar-close")
    let root = try await access.grant(folder: base)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    let tracker = SidebarLeaseTracker(root: base)
    let counter = SidebarBlockedCount(child: base.appendingPathComponent("Child"))
    controller.sidebarBrowserOverride = SidebarFolderBrowser(access: tracker, enumerator: counter)
    controller.browseRecoveredFolder(base, rootID: root)
    let tree = try sidebarTree(controller)
    try await waitForSidebar("close rows and scan") { tree.rows.map(\.folderURL).contains(counter.child) &&
        controller.session.folderScan?.sourceSnapshot?.isComplete == true }
    try await waitForSidebar("blocked count") { await counter.started > 0 }
    #expect(controller.gridShellVisible, "an imageless folder shows page 22, whose search is disabled")
    let childAcquiresAtClose = await tracker.childAcquires
    #expect(childAcquiresAtClose == 0)
    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
    controller.window?.close()
    await counter.release()
    try await waitForSidebar("released lease") { await tracker.active == 0 }
    #expect(await tracker.childAcquires == childAcquiresAtClose)
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebarCancelRestoresPriorTreeAndWatchRefreshRemovesDeletedChild() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = base.appendingPathComponent("A")
    let b = a.appendingPathComponent("B")
    let c = a.appendingPathComponent("C")
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    var needsEarlyCleanup = true
    defer { if needsEarlyCleanup { try? fm.removeItem(at: base) } }
    let image = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/portrait-2x3.png"))
    try image.write(to: a.appendingPathComponent("a.png"))
    try image.write(to: b.appendingPathComponent("b.png"))
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "sidebar-fix")
    let root = try await access.grant(folder: base)
    let directChildren = try await SidebarFolderBrowser(access: access,
        enumerator: SystemSidebarFolderEnumerator()).children(in: a, rootID: root)
    #expect(directChildren.map(\.lastPathComponent) == ["B"])
    let watch = Sidebar425Watch(WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: watch)
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    needsEarlyCleanup = false
    try await withAsyncTeardown {
        controller.browseRecoveredFolder(a, rootID: root)
        let tree = try sidebarTree(controller)
        try await sidebarCancelRestoreStages(controller, tree: tree, services: services, a: a, b: b, c: c, image: image)
    } teardown: {
        _ = await closeAndAwaitSidebarWatches(controller, watch: watch, testRoot: base)
    }
}

/// The tree rows and the folder scan, for a stage that never arrives (#425).
@MainActor private func sidebarState(_ controller: CanvasWindowController, tree: GridSidebarTreeView,
    testRoot: URL) -> String {
    let root = testRoot.standardizedFileURL.pathComponents
    func label(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.pathComponents
        guard path.starts(with: root) else { return "other" }
        let relative = path.dropFirst(root.count)
        return relative.isEmpty ? "." : relative.joined(separator: "/")
    }
    let rows = tree.rows.map { row in
        "\(label(row.folderURL))\(row.current ? " (current)" : "") count=\(row.countLabel.stringValue)"
    }
    let scan = controller.session.folderScan
    let scanFolder = scan?.sourceSnapshot.map { label($0.version.folder) } ?? "none"
    return "rows=\(rows) scan folder=\(scanFolder) " +
        "complete=\(scan?.sourceSnapshot?.isComplete == true) reading=\(scan?.isReadingFolder == true) " +
        "recursive=\(scan?.recursiveEnabled == true) entries=\(scan?.sourceSnapshot?.navigationEntries.count ?? 0) " +
        "grid=\(controller.gridShellVisible)"
}

@MainActor private func sidebarCancelRestoreStages(_ controller: CanvasWindowController, tree: GridSidebarTreeView,
    services: AccessServices, a: URL, b: URL, c: URL, image: Data) async throws {
    let fm = FileManager.default
    var atClick = "", afterCancel = ""
    let state = { "\(sidebarState(controller, tree: tree, testRoot: a.deletingLastPathComponent())); at B click: \(atClick); after Cancel: \(afterCancel)" }
    try await waitForSidebar("A scan", state: state) { controller.session.folderScan?.sourceSnapshot?.isComplete == true }
    try await waitForSidebar("A tree", state: state) {
        tree.rows.contains { sameSidebarURL($0.folderURL, b) }
    }
    try await waitForSidebar("direct counts", state: state) {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, a) })?.countLabel.stringValue == "1" &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.countLabel.stringValue == "1"
    }
    #expect(tree.rows.first(where: { sameSidebarURL($0.folderURL, a) })?.countLabel.stringValue == "1")
    _ = controller.session.setFolderRecursiveEnabled(true)
    try await waitForSidebar("recursive grid keeps direct tree count", state: state) {
        controller.session.folderScan?.sourceSnapshot?.navigationEntries.count == 2 &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, a) })?.countLabel.stringValue == "1"
    }
    atClick = sidebarState(controller, tree: tree, testRoot: a.deletingLastPathComponent())
    tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.performClick(nil)
    #expect(tree.rows.first(where: { $0.current }).map { sameSidebarURL($0.folderURL, b) } == true)
    let cancel = try sidebarCancelButton(controller)
    cancel.performClick(nil)
    afterCancel = sidebarState(controller, tree: tree, testRoot: a.deletingLastPathComponent())
    try await waitForSidebar("restore A tree", state: state) {
        tree.rows.first(where: { $0.current }).map { sameSidebarURL($0.folderURL, a) } == true &&
        tree.rows.contains { sameSidebarURL($0.folderURL, b) }
    }
    try fm.createDirectory(at: c, withIntermediateDirectories: true)
    try image.write(to: c.appendingPathComponent("c.png"))
    try await waitForSidebar("added C", refreshing: services.watch, state: state) {
        tree.rows.contains { sameSidebarURL($0.folderURL, c) } &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, c) })?.countLabel.stringValue == "1"
    }
    try image.write(to: c.appendingPathComponent("c2.png"))
    try await waitForSidebar("changed C image count", refreshing: services.watch, state: state) {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, c) })?.countLabel.stringValue == "2"
    }
    let d = a.appendingPathComponent("D")
    try fm.moveItem(at: c, to: d)
    try await waitForSidebar("renamed C to D", refreshing: services.watch, state: state) {
        !tree.rows.contains { sameSidebarURL($0.folderURL, c) } &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, d) })?.countLabel.stringValue == "2"
    }
    try fm.removeItem(at: b)
    try await waitForSidebar("removed B", refreshing: services.watch, state: state) {
        !tree.rows.contains { sameSidebarURL($0.folderURL, b) } &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, d) })?.countLabel.stringValue == "2"
    }
    #expect(!tree.rows.contains(where: { sameSidebarURL($0.folderURL, b) }))
}

// The watch and read fakes live below line 389 so the known-flaky pins at SidebarTreeControllerTests.swift:305 and
// :389 (scripts/ci/known-flaky.mjs, checked by flaky-gate.test.mjs) keep naming the same lines (#751).
private final class SidebarHandoffWatch: FolderWatching, @unchecked Sendable {
    private struct Subscription: FolderWatchSubscription {
        let subscription: any FolderWatchSubscription
        let didCancel: @Sendable () -> Void
        func cancel() async { await subscription.cancel(); didCancel() }
    }
    private let hub: WatchHub
    private let gate = SidebarHandoffGate(rearmsAbandonedHold: true)
    private let scanGate = SidebarHandoffGate()
    private let lock = NSLock()
    private var cancelledSubscriptions = 0, scanSubscriptions = 0, sidebarDeliveries = 0
    init(hub: WatchHub) { self.hub = hub }
    var isHolding: Bool { gate.isHolding }
    var cancelledSubscriptionCount: Int { lock.withLock { cancelledSubscriptions } }
    var scanSubscriptionCount: Int { lock.withLock { scanSubscriptions } }
    /// Changes the hub delivered to sidebar (recursive) subscriptions.
    var sidebarDeliveryCount: Int { lock.withLock { sidebarDeliveries } }
    var isScanSubscriptionHeld: Bool { scanGate.isHolding }
    var abandonedHolds: Int { gate.abandonedHolds }
    var registrationSpent: String? { gate.spent.map { "the replacement registration gate: \($0)" } }
    /// O2: the scan's own watch subscription took the sidebar registration gate, so the scan can never reach its
    /// snapshot and no canonical sidebar load can come (#751).
    var scanHoldsRegistration: String? {
        gate.holderTag == "scan" ? "the scan's watch subscription holds the sidebar registration gate" : nil
    }
    var state: String {
        "registration gate \(gate.state) cancelled=\(cancelledSubscriptionCount); " +
            "scan subscription gate \(scanGate.state) registered=\(scanSubscriptionCount)"
    }
    func armNextSubscription() { gate.arm() }
    func releaseSubscription() { gate.release() }
    func holdNextScanSubscription() { scanGate.arm() }
    func releaseScanSubscription() { scanGate.release() }
    func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
        onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription {
        // Only a sidebar load subscribes recursively (the folder scan does not), so the registration gate holds
        // sidebar registrations only and the scan's own watch never takes it (#751 O2).
        if recursive { await gate.holdIfArmed("sidebar") } else { await scanGate.holdIfArmed("scan") }
        let subscription = try await hub.subscribe(rootID: rootID, folder: folder, recursive: recursive) { [self] in
            if recursive { lock.withLock { sidebarDeliveries += 1 } }
            onChange()
        }
        if !recursive { lock.withLock { scanSubscriptions += 1 } }
        return Subscription(subscription: subscription) { [self] in
            lock.withLock { cancelledSubscriptions += 1 }
        }
    }
    func reconcileAll() { hub.reconcileAll() }
}

private final class SidebarHandoffEnumerator: SidebarFolderEnumerating, @unchecked Sendable {
    private let system = SystemSidebarFolderEnumerator()
    private let gate = SidebarHandoffGate(rearmsAbandonedHold: true)
    var isReadCaptured: Bool { gate.isHolding }
    var readSpent: String? { gate.spent.map { "the children read gate: \($0)" } }
    var state: String { "read gate \(gate.state)" }
    func armNextChildrenRead() { gate.arm() }
    func releaseChildrenRead() { gate.release() }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        let children = try await system.children(in: folder, root: root)
        await gate.holdIfArmed("read")
        try Task.checkCancellation()
        return children
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        try await system.imageCount(in: folder, root: root)
    }
}

/// An extra sidebar load the fixture can force at a fixed point of the handoff (#751).
enum SidebarHandoffOrdering: Sendable {
    /// The scan runs freely; its canonical sidebar load lands wherever the runner puts it.
    case free
    /// O1: the scan subscribes its watch, then parks at its scan until a reconcile load holds the replacement
    /// registration. Its first complete snapshot then starts the canonical sidebar load, which cancels that holder.
    case canonicalLoadCancelsHeldRegistration
    /// O2 then O1: the scan's own watch subscription waits until the sidebar gates are armed, then registers while
    /// the registration gate is armed; the run then continues as O1.
    case scanSubscribesAfterArming
}

@MainActor func expectSidebarHandoffDelivery(_ delivery: SidebarHandoffDelivery,
    ordering: SidebarHandoffOrdering = .free) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = base.appendingPathComponent("A"), b = a.appendingPathComponent("B")
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let image = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/portrait-2x3.png"))
    try image.write(to: a.appendingPathComponent("a.png"))
    try image.write(to: b.appendingPathComponent("b.png"))
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "sidebar-handoff")
    let root = try await access.grant(folder: base)
    let source = SidebarHandoffEventSource(), clock = SidebarHandoffClock()
    let hub = WatchHub(access: access, source: source, scheduler: clock)
    let watch = SidebarHandoffWatch(hub: hub)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: watch)
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    defer { controller.window?.close() }
    let enumerator = SidebarHandoffEnumerator(), scanner = SidebarHandoffScanner()
    controller.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: enumerator)
    let forcesScan = ordering != .free
    if forcesScan { controller.folderScanningOverride = scanner }
    if ordering == .scanSubscribesAfterArming { watch.holdNextScanSubscription() }
    defer {
        enumerator.releaseChildrenRead(); watch.releaseSubscription()
        watch.releaseScanSubscription(); scanner.releaseScan()
    }
    controller.browseRecoveredFolder(a, rootID: root)
    let tree = try sidebarTree(controller)
    let state = { "\(sidebarState(controller, tree: tree, testRoot: base)); \(watch.state); \(enumerator.state); \(scanner.state)" }
    try await waitForSidebar("initial tree", state: state) {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.countLabel.stringValue == "1"
    }
    // The scan subscribes its watch before it scans, so a scan parked at its scan has no subscription left that could
    // reach an armed gate (#751 O2).
    switch ordering {
    case .free: break
    case .canonicalLoadCancelsHeldRegistration:
        try await waitForSidebar("scan parked at its scan", state: state) { scanner.isHolding }
    case .scanSubscribesAfterArming:
        try await waitForSidebar("scan subscription held", state: state) { watch.isScanSubscriptionHeld }
    }
    let initialCancellationBaseline = watch.cancelledSubscriptionCount
    enumerator.armNextChildrenRead()
    watch.armNextSubscription()
    if ordering == .scanSubscribesAfterArming {
        watch.releaseScanSubscription()
        try await waitForSidebar("scan subscription registered", state: state,
            impossible: { watch.scanHoldsRegistration }) { watch.scanSubscriptionCount > 0 }
        try await waitForSidebar("scan parked at its scan", state: state) { scanner.isHolding }
    }
    watch.reconcileAll()
    // A sidebar load subscribes before it reads (#298), so the first load after arming holds the registration
    // before it reads. A load cancelled while it holds re-arms its gate for the load that replaced it.
    try await waitForSidebar("replacement registration held", state: state,
        impossible: { watch.scanHoldsRegistration ?? watch.registrationSpent }) { watch.isHolding }
    if forcesScan {
        let abandoned = watch.abandonedHolds
        scanner.releaseScan()
        try await waitForSidebar("canonical load cancelled the held registration", state: state,
            impossible: { watch.scanHoldsRegistration }) { watch.abandonedHolds > abandoned }
        try await waitForSidebar("canonical load holds the registration", state: state,
            impossible: { watch.registrationSpent }) { watch.isHolding }
    }
    let d = a.appendingPathComponent("D")
    switch delivery {
    case .beforeRegistrationRelease:
        // The change is delivered while the replacement registration is still held, before its load has read.
        let delivered = watch.sidebarDeliveryCount
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        source.emit(.changed(d))
        clock.fireScheduledChanges()
        #expect(watch.isHolding, "the change was delivered while the replacement registration was held")
        #expect(watch.sidebarDeliveryCount > delivered, "a change during the held registration reached a sidebar subscription")
        watch.releaseSubscription()
    case .afterOldSubscriptionRetires, .duringOwnedRead:
        watch.releaseSubscription()
        try await waitForSidebar("captured children without D", state: state,
            impossible: { enumerator.readSpent }) { enumerator.isReadCaptured }
        if case .afterOldSubscriptionRetires = delivery {
            try await waitForSidebar("old subscription retired before event", state: state) {
                watch.cancelledSubscriptionCount > initialCancellationBaseline
            }
        }
        // The change is delivered while the replacement load's own read is held.
        let delivered = watch.sidebarDeliveryCount
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        source.emit(.changed(d))
        clock.fireScheduledChanges()
        #expect(enumerator.isReadCaptured, "the change was delivered during the replacement load's held read")
        #expect(watch.sidebarDeliveryCount > delivered, "a change during the held read reached a sidebar subscription")
    }
    enumerator.releaseChildrenRead()
    // One external change must refresh D with count 0 without another event or reconcile.
    try await waitForSidebar("D refreshed to count 0 by one external change", state: state) {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, d) })?.countLabel.stringValue == "0"
    }
    #expect(tree.rows.contains { sameSidebarURL($0.folderURL, b) })
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebarWatchHandoffDeliversChangeDuringCapturedRead() async throws {
    try await expectSidebarHandoffDelivery(.beforeRegistrationRelease)
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebarWatchHandoffDeliversPendingChangeAfterOldSubscriptionRetires() async throws {
    try await expectSidebarHandoffDelivery(.afterOldSubscriptionRetires)
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebarWatchCallbackDuringOwnedReadTriggersFollowUpRefresh() async throws {
    try await expectSidebarHandoffDelivery(.duringOwnedRead)
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebar425DiagnosticStateSanitizesRowsAndScanAcrossPrivateRoots() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "sidebar425-diagnostics")
    let root = try await access.grant(folder: base)
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    defer { controller.window?.close() }
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
    let scan = FolderScanCoordinator(access: access, scanner: FolderBrowser())
    defer { scan.end() }
    // Shares a string prefix with the first root, but is not its descendant.
    let outside = base.appendingPathComponent("private-first-root-neighbor")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    var states: [String] = []
    for name in ["private-first-root", "private-second-root"] {
        let testRoot = base.appendingPathComponent(name)
        let a = testRoot.appendingPathComponent("A")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try Data([1]).write(to: a.appendingPathComponent("one.png"))
        tree.show(current: .init(url: a, count: 7), parent: nil, children: [
            .init(url: a.appendingPathComponent("B"), count: 2),
            .init(url: a.appendingPathComponent("C"), count: 3),
            .init(url: a.appendingPathComponent("D"), count: 4),
            .init(url: outside, count: 5),
        ])
        controller.session.folderScan = scan
        try await scan.begin(folder: a, rootID: root).value
        let state = sidebarState(controller, tree: tree, testRoot: testRoot)
        #expect(state.hasPrefix("rows=[\"A (current) count=7\", \"A/B count=2\", \"A/C count=3\", \"A/D count=4\", \"other count=5\"] scan folder=A "))
        #expect(state.contains("complete=true reading=false recursive=false entries=1"))
        #expect(!state.contains(base.path) && !state.contains("private-") && !state.contains("file://"))
        states.append(state)

        try await scan.begin(folder: outside, rootID: root).value
        let outsideState = sidebarState(controller, tree: tree, testRoot: testRoot)
        #expect(outsideState.contains("scan folder=other complete=true reading=false recursive=false entries=0"))
        #expect(!outsideState.contains(outside.path) && !outsideState.contains("private-first-root-neighbor"))

        controller.session.folderScan = nil
        let emptyState = sidebarState(controller, tree: tree, testRoot: testRoot)
        #expect(emptyState.contains("scan folder=none complete=false reading=false recursive=false entries=0"))
        #expect(!emptyState.contains(base.path))
    }
    #expect(states.count == 2 && states[0] == states[1])
}

/// Test-owned admission and completion tracking for watches, not a general controller-idle fence.
private final class Sidebar425Watch: FolderWatching, @unchecked Sendable {
    private final class Subscription: FolderWatchSubscription, @unchecked Sendable {
        private let subscription: any FolderWatchSubscription
        private let didCancel: @Sendable () -> Void
        private let lock = NSLock()
        private var cancellation: Task<Void, Never>?
        init(_ subscription: any FolderWatchSubscription, didCancel: @escaping @Sendable () -> Void) {
            self.subscription = subscription; self.didCancel = didCancel
        }
        func cancel() async {
            let task = lock.withLock {
                if let cancellation { return cancellation }
                let task = Task { [subscription, didCancel] in
                    await subscription.cancel()
                    didCancel()
                }
                cancellation = task
                return task
            }
            await task.value
        }
    }
    private let hub: any FolderWatching
    private let lock = NSLock()
    private var stopped = false
    private var registering = 0
    private var subscriptions: [UUID: Subscription] = [:]
    init(_ hub: any FolderWatching) { self.hub = hub }
    func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
        onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            registering += 1
        }
        defer { lock.withLock { registering -= 1 } }
        let underlying = try await hub.subscribe(rootID: rootID, folder: folder, recursive: recursive, onChange: onChange)
        let id = UUID()
        let subscription = Subscription(underlying) { [self] in
            _ = lock.withLock { subscriptions.removeValue(forKey: id) }
        }
        let retiring = lock.withLock { subscriptions[id] = subscription; return stopped }
        if retiring { await subscription.cancel(); throw CancellationError() }
        return subscription
    }
    func reconcileAll() {
        if lock.withLock({ !stopped }) { hub.reconcileAll() }
    }
    func stop() {
        let retiring = lock.withLock { stopped = true; return Array(subscriptions.values) }
        for subscription in retiring { Task { await subscription.cancel() } }
    }
    /// A fresh task gets its cleanup opportunity even when the caller's test has already been cancelled.
    func drain() async -> (completed: Bool, elapsed: Duration) {
        await Task.detached { [self] in
            let before = ContinuousClock.now
            let deadline = before + .seconds(2)
            while !lock.withLock({ registering == 0 && subscriptions.isEmpty }) {
                if ContinuousClock.now >= deadline { return (false, ContinuousClock.now - before) }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return (true, ContinuousClock.now - before)
        }.value
    }
}

/// Best effort for admitted watches only. An incomplete drain keeps the root and preserves the behavior result.
@MainActor private func closeAndAwaitSidebarWatches(_ controller: CanvasWindowController,
    watch: Sidebar425Watch, testRoot: URL) async -> (completed: Bool, elapsed: Duration) {
    watch.stop()
    // The controller is the NSWindow delegate; close delivers windowWillClose exactly once.
    controller.window?.close()
    let result = await watch.drain()
    if result.completed { try? FileManager.default.removeItem(at: testRoot) }
    else { print("sidebar watch teardown: best-effort 2-second limit reached; test root retained") }
    return result
}

/// Gates the external lease boundary while the real WatchHub runs its transitions.
private actor Sidebar425GatedLeases: AccessLeasing {
    nonisolated let acquireGate = SidebarHandoffGate()
    nonisolated let releaseGate = SidebarHandoffGate()
    let root: URL
    private(set) var active = 0
    init(root: URL = URL(fileURLWithPath: "/sidebar425")) { self.root = root }
    func acquire(_ request: AccessRequest) async -> AccessLease {
        await acquireGate.holdIfArmed()
        active += 1
        return AccessLease(url: root, rootID: nil)
    }
    func release(_ lease: AccessLease) async {
        await releaseGate.holdIfArmed()
        active -= 1
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func sidebar425TeardownIncludesAcquireBeforeAnyLeaseExists() async throws {
    let leases = Sidebar425GatedLeases(), source = SidebarHandoffEventSource()
    let watch = Sidebar425Watch(WatchHub(access: leases, source: source, scheduler: SidebarHandoffClock()))
    let started = StartedTasks(), root = AccessRootID()
    leases.acquireGate.arm()
    let registration = started.track(Task {
        try await watch.subscribe(rootID: root, folder: URL(fileURLWithPath: "/sidebar425/A"), recursive: true) { }
    })
    try await withAsyncTeardown {
        try await waitUntil { leases.acquireGate.isHolding }
        #expect(await leases.active == 0)
        watch.stop()
        var finished: Bool?
        let draining = started.track(Task { @MainActor in finished = (await watch.drain()).completed })
        try await Task.sleep(for: .milliseconds(30))
        #expect(finished == nil, "zero leases cannot finish teardown while registration is acquiring")
        leases.acquireGate.release()
        await #expect(throws: CancellationError.self) { _ = try await registration.value }
        await draining.value
        #expect(finished == true && source.liveStreams == 0)
        #expect(await leases.active == 0)
        await #expect(throws: CancellationError.self) {
            let unexpected = try await watch.subscribe(rootID: root, folder: URL(fileURLWithPath: "/sidebar425/B"), recursive: true) { }
            await unexpected.cancel()
        }
    } teardown: {
        watch.stop(); leases.acquireGate.release(); leases.releaseGate.release()
        if let subscription = try? await registration.value { await subscription.cancel() }
        started.cancelAll(); await started.awaitAll()
    }
}

@Test(.timeLimit(.minutes(3)), arguments: [false, true]) @MainActor
func sidebar425TeardownJoinsDuplicateCancelEvenForCancelledCaller(cancelled: Bool) async throws {
    let leases = Sidebar425GatedLeases(), source = SidebarHandoffEventSource()
    let watch = Sidebar425Watch(WatchHub(access: leases, source: source, scheduler: SidebarHandoffClock()))
    let started = StartedTasks()
    let subscription = try await watch.subscribe(rootID: AccessRootID(), folder: URL(fileURLWithPath: "/sidebar425/A"), recursive: true) { }
    leases.releaseGate.arm()
    let first = started.track(Task { await subscription.cancel() })
    try await withAsyncTeardown {
        try await waitUntil { leases.releaseGate.isHolding }
        let duplicate = started.track(Task { await subscription.cancel() })
        watch.stop()
        var finished: Bool?
        let draining = started.track(Task { @MainActor in finished = (await watch.drain()).completed })
        if cancelled { draining.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(finished == nil, "duplicate cancel and parent cancellation cannot finish before real lease release")
        leases.releaseGate.release()
        await first.value; await duplicate.value; await draining.value
        #expect(finished == true && source.liveStreams == 0)
        #expect(await leases.active == 0)
        watch.stop()
        #expect((await watch.drain()).completed)
    } teardown: {
        watch.stop(); leases.acquireGate.release(); leases.releaseGate.release()
        started.cancelAll(); await started.awaitAll()
        await subscription.cancel()
    }
}

private enum Sidebar425BehaviorError: Error, Equatable { case original }

@Test(.timeLimit(.minutes(3))) @MainActor func sidebar425TeardownTimeoutRetainsRootAndOriginalErrorWithoutThrowing() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default, started = StartedTasks()
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let sentinel = base.appendingPathComponent("sentinel")
    try Data([1]).write(to: sentinel)
    let leases = Sidebar425GatedLeases(root: base), source = SidebarHandoffEventSource()
    let watch = Sidebar425Watch(WatchHub(access: leases, source: source, scheduler: SidebarHandoffClock()))
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    let subscription = try await watch.subscribe(rootID: AccessRootID(), folder: base, recursive: true) { }
    leases.releaseGate.arm()
    let cancellation = started.track(Task { await subscription.cancel() })
    try await withAsyncTeardown {
        try await waitUntil { leases.releaseGate.isHolding }
        do {
            try await withAsyncTeardown { throw Sidebar425BehaviorError.original } teardown: {
                let before = ContinuousClock.now
                let (completed, drainElapsed) = await closeAndAwaitSidebarWatches(controller, watch: watch, testRoot: base)
                let elapsed = ContinuousClock.now - before
                #expect(!completed)
                #expect(drainElapsed < .seconds(5), "detached two-second drain has three seconds of scheduling margin, excluding the main-actor hop")
                #expect(elapsed >= .milliseconds(1800), "two-second drain must not time out early; main-actor queueing can delay observation")
                #expect(fm.fileExists(atPath: sentinel.path))
            }
            #expect(Bool(false), "original behavior error was swallowed by cleanup")
        } catch {
            #expect(error as? Sidebar425BehaviorError == .original)
        }
        leases.releaseGate.release()
        await cancellation.value
        #expect((await closeAndAwaitSidebarWatches(controller, watch: watch, testRoot: base)).completed)
        #expect(!fm.fileExists(atPath: base.path))
        #expect(await leases.active == 0 && source.liveStreams == 0)
    } teardown: {
        watch.stop(); leases.acquireGate.release(); leases.releaseGate.release()
        started.cancelAll(); await started.awaitAll()
        await subscription.cancel()
        controller.window?.close()
    }
}
