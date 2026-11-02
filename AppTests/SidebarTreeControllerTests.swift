import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

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

@MainActor private func waitForSidebar(_ stage: String, refreshing watch: (any FolderWatching)? = nil,
    fileID: String = #fileID, line: Int = #line, _ condition: () async -> Bool) async throws {
    watch?.reconcileAll()
    try await waitUntil("sidebar stage: \(stage)", fileID: fileID, line: line) { await condition() }
}

@MainActor private func sidebarCondition(for seconds: Double,
    _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while await !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private final class SidebarHandoffGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var released = false
    private var holding = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { lock.withLock { holding } }
    func arm() {
        lock.withLock { armed = true; released = false; holding = false }
    }
    func holdIfArmed() async {
        guard lock.withLock({ () -> Bool in
            guard armed else { return false }
            armed = false; holding = true
            return true
        }) else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { holding = false; return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: { release() }
    }
    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true; holding = false
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final class SidebarHandoffWatch: FolderWatching, @unchecked Sendable {
    private struct Subscription: FolderWatchSubscription {
        let subscription: any FolderWatchSubscription
        let didCancel: @Sendable () -> Void
        func cancel() async {
            await subscription.cancel()
            didCancel()
        }
    }
    private let hub: WatchHub
    private let gate = SidebarHandoffGate()
    private let lock = NSLock()
    private var cancelledSubscriptions = 0
    init(hub: WatchHub) { self.hub = hub }
    var isHolding: Bool { gate.isHolding }
    var cancelledSubscriptionCount: Int { lock.withLock { cancelledSubscriptions } }
    func armNextSubscription() { gate.arm() }
    func releaseSubscription() { gate.release() }
    func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
        onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription {
        await gate.holdIfArmed()
        let subscription = try await hub.subscribe(rootID: rootID, folder: folder, recursive: recursive, onChange: onChange)
        return Subscription(subscription: subscription) { [self] in
            lock.withLock { cancelledSubscriptions += 1 }
        }
    }
    func reconcileAll() { hub.reconcileAll() }
}

private final class SidebarHandoffEnumerator: SidebarFolderEnumerating, @unchecked Sendable {
    private let system = SystemSidebarFolderEnumerator()
    private let gate = SidebarHandoffGate()
    var isReadCaptured: Bool { gate.isHolding }
    func armNextChildrenRead() { gate.arm() }
    func releaseChildrenRead() { gate.release() }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        let children = try await system.children(in: folder, root: root)
        await gate.holdIfArmed()
        try Task.checkCancellation()
        return children
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        try await system.imageCount(in: folder, root: root)
    }
}

private final class SidebarHandoffEventSource: FolderEventSource, @unchecked Sendable {
    private struct Stream: FolderEventStream {
        let onStop: @Sendable () -> Void
        func stop() { onStop() }
    }
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable ([FolderChangeHint]) -> Void] = [:]
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
    defer { try? fm.removeItem(at: base) }
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
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: SidebarMotionSource()))
    defer { controller.window?.close() }
    controller.browseRecoveredFolder(a, rootID: root)
    let tree = try sidebarTree(controller)
    try await waitForSidebar("A scan") { controller.session.folderScan?.sourceSnapshot?.isComplete == true }
    try await waitForSidebar("A tree") {
        tree.rows.contains { sameSidebarURL($0.folderURL, b) }
    }
    try await waitForSidebar("direct counts") {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, a) })?.countLabel.stringValue == "1" &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.countLabel.stringValue == "1"
    }
    #expect(tree.rows.first(where: { sameSidebarURL($0.folderURL, a) })?.countLabel.stringValue == "1")
    _ = controller.session.setFolderRecursiveEnabled(true)
    try await waitForSidebar("recursive grid keeps direct tree count") {
        controller.session.folderScan?.sourceSnapshot?.navigationEntries.count == 2 &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, a) })?.countLabel.stringValue == "1"
    }
    tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.performClick(nil)
    #expect(tree.rows.first(where: { $0.current }).map { sameSidebarURL($0.folderURL, b) } == true)
    let cancel = try sidebarCancelButton(controller)
    cancel.performClick(nil)
    try await waitForSidebar("restore A tree") {
        tree.rows.first(where: { $0.current }).map { sameSidebarURL($0.folderURL, a) } == true &&
        tree.rows.contains { sameSidebarURL($0.folderURL, b) }
    }
    try fm.createDirectory(at: c, withIntermediateDirectories: true)
    try image.write(to: c.appendingPathComponent("c.png"))
    try await waitForSidebar("added C", refreshing: services.watch) {
        tree.rows.contains { sameSidebarURL($0.folderURL, c) } &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, c) })?.countLabel.stringValue == "1"
    }
    try image.write(to: c.appendingPathComponent("c2.png"))
    try await waitForSidebar("changed C image count", refreshing: services.watch) {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, c) })?.countLabel.stringValue == "2"
    }
    let d = a.appendingPathComponent("D")
    try fm.moveItem(at: c, to: d)
    try await waitForSidebar("renamed C to D", refreshing: services.watch) {
        !tree.rows.contains { sameSidebarURL($0.folderURL, c) } &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, d) })?.countLabel.stringValue == "2"
    }
    try fm.removeItem(at: b)
    try await waitForSidebar("removed B", refreshing: services.watch) {
        !tree.rows.contains { sameSidebarURL($0.folderURL, b) } &&
        tree.rows.first(where: { sameSidebarURL($0.folderURL, d) })?.countLabel.stringValue == "2"
    }
    #expect(!tree.rows.contains(where: { sameSidebarURL($0.folderURL, b) }))
}

private enum SidebarHandoffDelivery {
    case beforeRegistrationRelease, afterOldSubscriptionRetires, duringOwnedRead
}

@MainActor private func expectSidebarHandoffDelivery(_ delivery: SidebarHandoffDelivery) async throws {
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
    let enumerator = SidebarHandoffEnumerator()
    controller.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: enumerator)
    defer { enumerator.releaseChildrenRead(); watch.releaseSubscription() }
    controller.browseRecoveredFolder(a, rootID: root)
    let tree = try sidebarTree(controller)
    try await waitForSidebar("initial tree") {
        tree.rows.first(where: { sameSidebarURL($0.folderURL, b) })?.countLabel.stringValue == "1"
    }
    let initialCancellationBaseline = watch.cancelledSubscriptionCount
    enumerator.armNextChildrenRead()
    watch.armNextSubscription()
    watch.reconcileAll()
    try await waitForSidebar("first refresh boundary") { enumerator.isReadCaptured || watch.isHolding }
    var subscriptionFirst = false
    if watch.isHolding && !enumerator.isReadCaptured {
        _ = await sidebarCondition(for: 0.25) { enumerator.isReadCaptured }
        if !enumerator.isReadCaptured {
            subscriptionFirst = true
            watch.releaseSubscription()
        }
    }
    try await waitForSidebar("captured children without D") { enumerator.isReadCaptured }
    if !subscriptionFirst {
        try await waitForSidebar("replacement registration held") { watch.isHolding }
    } else if case .afterOldSubscriptionRetires = delivery {
        try await waitForSidebar("old subscription retired before event") {
            watch.cancelledSubscriptionCount > initialCancellationBaseline
        }
    }
    let d = a.appendingPathComponent("D")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    source.emit(.changed(d))
    switch delivery {
    case .beforeRegistrationRelease:
        clock.fireScheduledChanges()
        watch.releaseSubscription()
    case .afterOldSubscriptionRetires:
        let retirementBaseline = watch.cancelledSubscriptionCount
        watch.releaseSubscription()
        if !subscriptionFirst {
            try await waitForSidebar("old subscription retired after event") {
                watch.cancelledSubscriptionCount > retirementBaseline
            }
        }
        clock.fireScheduledChanges()
    case .duringOwnedRead:
        watch.releaseSubscription()
        clock.fireScheduledChanges()
    }
    enumerator.releaseChildrenRead()
    // One external change must refresh D with count 0 without another event or reconcile.
    try await waitForSidebar("D refreshed to count 0 by one external change") {
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
