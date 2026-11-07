import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// Real enumeration with explicit attempt-scoped completion/failure, including cancellation drainage.
private actor Recount454Scanner: FolderScanning {
    private let browser = FolderBrowser()
    private var attempts: [String: Int] = [:]
    private var active: Set<String> = []
    private var held: [String: CheckedContinuation<Bool, Never>] = [:]
    private func key(_ folder: URL, _ attempt: Int) -> String { "\(folder.standardizedFileURL.path)#\(attempt)" }
    func isHolding(_ folder: URL, attempt: Int) -> Bool { held[key(folder, attempt)] != nil }
    var allEnded: Bool { active.isEmpty }
    func release(_ folder: URL, attempt: Int, fail: Bool = false) {
        held.removeValue(forKey: key(folder, attempt))?.resume(returning: fail)
    }
    func releaseAll() {
        let continuations = Array(held.values)
        held.removeAll()
        for continuation in continuations { continuation.resume(returning: false) }
    }
    private func cancelled(_ key: String) { held.removeValue(forKey: key)?.resume(returning: false) }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let path = folder.standardizedFileURL.path
        attempts[path, default: 0] += 1
        let key = key(folder, attempts[path]!)
        active.insert(key)
        defer { active.remove(key) }
        try await browser.scan(in: folder, root: root, options: options, emit: emit)
        let fail = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { held[key] = continuation }
            }
        } onCancel: { Task { await self.cancelled(key) } }
        try Task.checkCancellation()
        if fail { throw CocoaError(.fileReadUnknown) }
    }
}

@MainActor private final class Recount454Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func recount454Find<T: NSView>(_ type: T.Type, in view: NSView?,
    matching: (T) -> Bool) -> T? {
    guard let view else { return nil }
    if let found = view as? T, matching(found) { return found }
    for child in view.subviews {
        if let found = recount454Find(type, in: child, matching: matching) { return found }
    }
    return nil
}

/// The external watch boundary chooses sidebar events without also refreshing the flat main snapshot.
private final class Recount454Watch: FolderWatching, @unchecked Sendable {
    private struct Subscription: FolderWatchSubscription {
        let cancelBody: @Sendable () -> Void
        func cancel() async { cancelBody() }
    }
    private let lock = NSLock()
    private var stopped = false
    private var callbacks: [UUID: (recursive: Bool, body: @Sendable () -> Void)] = [:]
    var recursiveCount: Int { lock.withLock { callbacks.values.filter(\.recursive).count } }
    var liveCount: Int { lock.withLock { callbacks.count } }
    func subscribe(rootID: AccessRootID, folder: URL, recursive: Bool,
                   onChange: @escaping @Sendable () -> Void) async throws -> any FolderWatchSubscription {
        try Task.checkCancellation()
        let id = UUID()
        try lock.withLock {
            if stopped { throw CancellationError() }
            callbacks[id] = (recursive, onChange)
        }
        return Subscription { [self] in _ = lock.withLock { callbacks.removeValue(forKey: id) } }
    }
    func reconcileAll() { fireSidebar() }
    func fireSidebar() {
        let due = lock.withLock { callbacks.values.filter(\.recursive).map(\.body) }
        for callback in due { callback() }
    }
    func stop() { lock.withLock { stopped = true; callbacks.removeAll() } }
}

/// Each count is computed from real files before a test may hold/fault its boundary result.
private actor Recount454Enumerator: SidebarFolderEnumerating {
    private let system = SystemSidebarFolderEnumerator()
    private var armed: [String: UUID] = [:]
    private var waits: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<UUID> = []
    private var captured: [UUID: Int] = [:]
    private var finished: Set<UUID> = []
    private var cancelled: [UUID: Bool] = [:]
    private var failures: Set<String> = []
    private var failureCounts: [String: Int] = [:]
    private var calls: [String: Int] = [:]
    private var latest: [String: Int] = [:]
    private var allReleased = false
    private var active = 0
    var allEnded: Bool { active == 0 }
    private func path(_ url: URL) -> String { url.standardizedFileURL.path }
    func arm(_ folder: URL) -> UUID {
        let id = UUID()
        armed[path(folder)] = id
        return id
    }
    func capturedValue(_ id: UUID) -> Int? { captured[id] }
    func isFinished(_ id: UUID) -> Bool { finished.contains(id) }
    func wasCancelled(_ id: UUID) -> Bool { cancelled[id] == true }
    func callCount(_ folder: URL) -> Int { calls[path(folder), default: 0] }
    func failureCount(_ folder: URL) -> Int { failureCounts[path(folder), default: 0] }
    func latestCount(_ folder: URL) -> Int? { latest[path(folder)] }
    func setFailing(_ folder: URL, _ failing: Bool) {
        if failing { failures.insert(path(folder)) } else { failures.remove(path(folder)) }
    }
    func release(_ id: UUID) { released.insert(id); waits.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        allReleased = true
        let pending = Array(waits.values)
        waits.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        active += 1
        defer { active -= 1 }
        return try await system.children(in: folder, root: root)
    }
    func imageCount(in folder: URL, root: URL) async throws -> Int {
        active += 1
        defer { active -= 1 }
        let folderPath = path(folder)
        calls[folderPath, default: 0] += 1
        let count = try await system.imageCount(in: folder, root: root)
        if let id = armed.removeValue(forKey: folderPath) {
            captured[id] = count
            // Intentionally keep the old result held after cancellation; a later generation can finish first.
            if !allReleased && !released.contains(id) {
                await withCheckedContinuation { waits[id] = $0 }
            }
            cancelled[id] = Task.isCancelled
            finished.insert(id)
        }
        if failures.contains(folderPath) {
            failureCounts[folderPath, default: 0] += 1
            throw CocoaError(.fileReadUnknown)
        }
        latest[folderPath] = count
        return count
    }
}

@MainActor private final class Recount454Fixture {
    let base: URL, root: URL, child: URL, sibling: URL
    let rootID: AccessRootID, png: Data
    let watch = Recount454Watch()
    let counter = Recount454Enumerator()
    let scanner = Recount454Scanner()
    let controller: CanvasWindowController
    let window: NSWindow
    init(childCount: Int = 1) async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recount454-\(UUID())")
        root = base.appendingPathComponent("Root")
        child = root.appendingPathComponent("A-Child")
        sibling = root.appendingPathComponent("Z-Sibling")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        png = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png"))
        for (folder, count) in [(root, 3), (child, childCount), (sibling, 1)] {
            for i in 0..<count { try png.write(to: folder.appendingPathComponent("image-\(i).png")) }
        }
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "recount454")
        rootID = try await access.grant(folder: root)
        let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: watch)
        let created = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Recount454Motion()))
        controller = created
        window = try #require(created.window)
        created.folderScanningOverride = scanner
        created.sidebarBrowserOverride = SidebarFolderBrowser(access: access, enumerator: counter)
        window.setContentSize(NSSize(width: 1280, height: 800))
    }
    var shell: GridShellView? { recount454Find(GridShellView.self, in: window.contentView) { _ in true } }
    func present() { window.update(); window.contentView?.layoutSubtreeIfNeeded() }
    func row(_ folder: URL) -> GridSidebarFolderButton? {
        recount454Find(GridSidebarFolderButton.self, in: window.contentView) {
            $0.folderURL.standardizedFileURL.path == folder.standardizedFileURL.path
        }
    }
    func button(_ identifier: String) -> NSButton? {
        recount454Find(NSButton.self, in: window.contentView) {
            $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor
        }
    }
    func wait(_ description: String, _ condition: () async -> Bool) async throws {
        try await MadoAppTests.waitUntil(description, between: { self.present() }, condition)
        present()
    }
    func expectCount(_ folder: URL, _ count: Int?) throws {
        let folderRow = try #require(self.row(folder))
        #expect(folderRow.countLabel.stringValue == (count.map(String.init) ?? ""))
        #expect(folderRow.countLabel.isHidden == (count == nil))
        let images = count.map { String(format: String(localized: "%lld images"), Int64($0)) }
        #expect(folderRow.accessibilityLabel() == (images.map { "\(folder.lastPathComponent), \($0)" } ?? folder.lastPathComponent))
        #expect(!window.isVisible)
    }
    func writeCount(_ count: Int, in folder: URL) throws {
        let fm = FileManager.default
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
            try fm.removeItem(at: file)
        }
        for i in 0..<count { try png.write(to: folder.appendingPathComponent("image-\(i).png")) }
        #expect(try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.count == count)
    }
    func baseline(childCount: Int = 1) async throws {
        controller.browseRecoveredFolder(root, rootID: rootID)
        try await wait("initial main read and full sidebar pass") {
            await self.scanner.isHolding(self.root, attempt: 1)
                && self.row(self.child)?.countLabel.stringValue == String(childCount)
                && self.row(self.sibling)?.countLabel.stringValue == "1"
        }
        try expectCount(root, nil)
        await scanner.release(root, attempt: 1)
        try await wait("baseline complete with all real counts") {
            self.controller.session.folderScan?.sourceSnapshot?.isComplete == true
                && self.controller.session.folderScan?.isScanning == false
                && self.row(self.root)?.countLabel.stringValue == "3"
                && self.row(self.child)?.countLabel.stringValue == String(childCount)
                && self.row(self.sibling)?.countLabel.stringValue == "1"
                && self.watch.recursiveCount == 1
        }
        try expectCount(root, 3)
        try expectCount(child, childCount)
        try expectCount(sibling, 1)
    }
    func beginHeldMain(childCount: Int = 1) async throws {
        controller.browseRecoveredFolder(root, rootID: rootID)
        try await wait("new main Reading with current-generation sidebar pass") {
            await self.scanner.isHolding(self.root, attempt: 2)
                && self.controller.session.folderScan?.isReadingFolder == true
                && self.row(self.child)?.countLabel.stringValue == String(childCount)
                && self.row(self.sibling)?.countLabel.stringValue == "1"
                && self.watch.recursiveCount == 1
        }
        try expectCount(root, nil)
        try expectCount(child, childCount)
    }
    func refreshSidebar() { watch.fireSidebar() }
    func close() async {
        watch.stop()
        await counter.releaseAll()
        await scanner.releaseAll()
        window.close()
        try? await MadoAppTests.waitUntil("recount boundary and scanner teardown") {
            await self.counter.releaseAll()
            let countsEnded = await self.counter.allEnded
            let scanEnded = await self.scanner.allEnded
            return countsEnded && scanEnded && self.watch.liveCount == 0
        }
        try? FileManager.default.removeItem(at: base)
    }
}

/// C1 / S5: equal URLs cannot carry counts across root, child or later-sibling rebuilds.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454RecountPendingRebuildInvalidatesRootChildAndSibling() async throws {
    for targetRole in ["root", "child", "sibling"] {
        let f = try await Recount454Fixture()
        try await withAsyncTeardown {
            try await f.baseline()
            let target = targetRole == "root" ? f.root : targetRole == "child" ? f.child : f.sibling
            let expected = targetRole == "root" ? 0 : 2
            let oldRow = try #require(f.row(target))
            try f.writeCount(expected, in: target)
            let gate = await f.counter.arm(target)
            f.refreshSidebar()
            try await f.wait("\(targetRole) real replacement count captured after rebuild") {
                await f.counter.capturedValue(gate) == expected && f.row(target) !== oldRow
            }
            try f.expectCount(target, nil)
            if targetRole != "root" { try f.expectCount(f.root, 3) }
            if targetRole == "sibling" { try f.expectCount(f.child, 1) }
            await f.counter.release(gate)
            try await f.wait("\(targetRole) fresh real count displayed") {
                f.row(target)?.countLabel.stringValue == String(expected) && f.watch.recursiveCount == 1
            }
            try f.expectCount(target, expected)
            if targetRole != "root" { try f.expectCount(f.root, 3) }
        } teardown: { await f.close() }
    }
}

/// C2 / S5: failed current/noncurrent recounts stay unknown through main completion and cancel.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454RecountFailureCannotRevealOldCountWhenReadingEnds() async throws {
    for targetIsRoot in [true, false] {
        for cancel in [false, true] {
            let f = try await Recount454Fixture()
            try await withAsyncTeardown {
                try await f.baseline()
                try await f.beginHeldMain()
                let target = targetIsRoot ? f.root : f.child
                let freshCount = targetIsRoot ? 0 : 2
                try f.writeCount(freshCount, in: target)
                try f.writeCount(2, in: f.sibling)
                let gate = await f.counter.arm(target)
                let oldSibling = try #require(f.row(f.sibling))
                f.refreshSidebar()
                try await f.wait("failed-recount boundary captures real changed count") {
                    await f.counter.capturedValue(gate) == freshCount
                }
                try f.expectCount(target, nil)
                if !targetIsRoot { try f.expectCount(f.root, nil) }
                await f.counter.setFailing(target, true)
                await f.counter.release(gate)
                try await f.wait("failed target processed before later sibling callback") {
                    await f.counter.failureCount(target) > 0 && f.row(f.sibling) !== oldSibling
                        && f.row(f.sibling)?.countLabel.stringValue == "2"
                }
                try f.expectCount(target, nil)
                try f.expectCount(f.sibling, 2)
                #expect(f.controller.session.folderScan?.isReadingFolder == true)
                let terminalSibling = try #require(f.row(f.sibling))
                let previousFailures = await f.counter.failureCount(target)
                if cancel { try #require(f.button("state.cancel-folder")).performClick(nil) }
                else { await f.scanner.release(f.root, attempt: 2) }
                try await f.wait("main terminal state and a fully processed failed recount") {
                    await f.counter.failureCount(target) > previousFailures
                        && f.controller.session.folderScan?.isReadingFolder == false
                        && f.row(f.sibling) !== terminalSibling
                        && f.row(f.sibling)?.countLabel.stringValue == "2"
                        && f.watch.recursiveCount == 1
                }
                #expect(f.shell?.readingFolderURL == nil)
                try f.expectCount(target, nil)
                try f.expectCount(f.sibling, 2)
                if !targetIsRoot { try f.expectCount(f.root, 3) }
                await f.counter.setFailing(target, false)
                f.refreshSidebar()
                try await f.wait("fresh successful recount after failure") {
                    f.row(target)?.countLabel.stringValue == String(freshCount)
                        && f.row(f.sibling)?.countLabel.stringValue == "2"
                        && f.watch.recursiveCount == 1
                }
                try f.expectCount(target, freshCount)
                try f.expectCount(f.sibling, 2)
            } teardown: { await f.close() }
        }
    }
}

/// C3 / S5: cancelled old count2 cannot overwrite replacement0, including after Reading unmasks.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue454RecountSupersededTwoCannotOverwriteFreshZero() async throws {
    for targetIsRoot in [true, false] {
        for reading in [false, true] {
            let f = try await Recount454Fixture(childCount: 3)
            try await withAsyncTeardown {
                try await f.baseline(childCount: 3)
                if reading { try await f.beginHeldMain(childCount: 3) }
                let target = targetIsRoot ? f.root : f.child
                try f.writeCount(2, in: target)
                let oldGate = await f.counter.arm(target)
                f.refreshSidebar()
                try await f.wait("superseded recount captured actual2") { await f.counter.capturedValue(oldGate) == 2 }
                try f.expectCount(target, nil)
                try f.writeCount(0, in: target)
                let oldSibling = try #require(f.row(f.sibling))
                f.refreshSidebar()
                try await f.wait("replacement count0 and later sibling callback") {
                    await f.counter.latestCount(target) == 0 && f.row(f.sibling) !== oldSibling
                        && f.row(f.sibling)?.countLabel.stringValue == "1"
                        && f.watch.recursiveCount == 1
                }
                try f.expectCount(target, reading && targetIsRoot ? nil : 0)
                try f.expectCount(f.sibling, 1)
                await f.counter.release(oldGate)
                try await f.wait("old captured result returned and all counter adapters drained") {
                    let returned = await f.counter.isFinished(oldGate)
                    let ended = await f.counter.allEnded
                    return returned && ended
                }
                f.present()
                try f.expectCount(target, reading && targetIsRoot ? nil : 0)
                try f.expectCount(f.sibling, 1)
                if reading {
                    await f.scanner.release(f.root, attempt: 2)
                    try await f.wait("main ends Reading with fresh0 retained") {
                        f.controller.session.folderScan?.isReadingFolder == false
                            && f.row(target)?.countLabel.stringValue == "0"
                            && f.row(f.sibling)?.countLabel.stringValue == "1"
                            && f.watch.recursiveCount == 1
                    }
                    #expect(f.shell?.readingFolderURL == nil)
                    try f.expectCount(target, 0)
                    try f.expectCount(f.sibling, 1)
                }
                #expect(await f.counter.capturedValue(oldGate) == 2)
                #expect(await f.counter.wasCancelled(oldGate), "the returned old2 belongs to the superseded cancelled recount")
            } teardown: { await f.close() }
        }
    }
}
