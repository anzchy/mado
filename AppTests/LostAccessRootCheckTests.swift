import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

// Audit M1: reader failures and app activation must not each start a full
// root listing. Every root check enumerates mounts once, so the mount port
// counts root checks.
private final class RootCheckBookmarks: SecurityScope, BookmarkCoding, @unchecked Sendable {
    private let lock = NSLock()
    private var scopes = 0
    private var relocated: URL?
    private var resolutionFails = false
    func relocate(to url: URL) { lock.withLock { relocated = url } }
    func failResolution() { lock.withLock { resolutionFails = true } }
    var activeScopes: Int { lock.withLock { scopes } }
    func start(_ url: URL) -> Bool { lock.withLock { scopes += 1 }; return true }
    func stop(_ url: URL) { lock.withLock { scopes -= 1 } }
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        try lock.withLock {
            if resolutionFails { throw CocoaError(.fileReadNoSuchFile) }
            return ResolvedBookmark(url: relocated ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
        }
    }
}

// #231: each automatic check must preserve the specific proven cause and revoke
// work admitted before loss. The codec simulates OS bookmark resolution only.
@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["reader", "foreground", "wake"], [false, true])
func t231ReadForegroundWakeReportNotFoundAndInvalidateOldWork(_ event: String, _ trash: Bool) async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let context = try await f.monitor.readContext(for: f.root)
    var trashed: NSURL?
    defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }
    if trash {
        try FileManager.default.trashItem(at: f.base.appendingPathComponent("Root"), resultingItemURL: &trashed)
        f.codec.relocate(to: try #require(trashed as URL?))
    } else { f.codec.failResolution() }
    if event == "reader" {
        await f.monitor.reportReadFailure(f.root, from: context.stamp)
    } else if event == "foreground" {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    } else {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    }
    while f.monitor.state.snapshot(for: f.root)?.availability == .readable { await Task.yield() }
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .lost(.notFound))
    #expect(!f.monitor.state.mayDeliver(context.stamp))
    #expect(!context.permit.isCurrent)
    let lostCounter = f.monitor.state.snapshot(for: f.root)?.counter
    await f.monitor.reportReadFailure(f.root, from: context.stamp)
    #expect(f.monitor.state.snapshot(for: f.root)?.counter == lostCounter)
    #expect(f.monitor.state.permit(for: f.root) == nil)
    #expect(f.codec.activeScopes == 0)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t231OfflineLaunchWithMountedMissingBookmarkRegistersNotFound() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    f.codec.failResolution()
    let files = try FileAccess(scope: f.codec, bookmarks: f.codec,
        store: BookmarkStore(url: f.base.appendingPathComponent("roots.json")), buildSHA: "T231-launch",
        bookmarkVolume: { _ in AccessProbeVolume(uuid: "111", url: nil, name: "Disk") },
        resolvedVolumeUUID: { _ in "111" }, mountedVolumesProvider: {
            [AccessProbeVolume(uuid: "111", url: nil, name: "Disk")]
        })
    let monitor = AccessMonitor(files: files, mounts: f.mounts)
    await monitor.register(f.root)
    #expect(monitor.state.snapshot(for: f.root)?.availability == .lost(.notFound))
    #expect(monitor.state.permit(for: f.root) == nil)
}
private actor RootCheckMounts: DiskMountPort {
    private let volumes = [AccessProbeVolume(uuid: "111", url: nil, name: "Disk")]
    private var connected = true
    func disconnect() { connected = false }
    private var pauseNext = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var enumerations = 0
    private(set) var paused = false
    func mountedVolumes() async -> [AccessProbeVolume] {
        enumerations += 1
        if pauseNext {
            pauseNext = false; paused = true
            await withCheckedContinuation { waiting.append($0) }
        }
        return connected ? volumes : []
    }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { _ in } }
    func pauseEnumeration() { pauseNext = true; paused = false }
    func release() {
        paused = false
        let held = waiting; waiting = []
        for continuation in held { continuation.resume() }
    }
}
@MainActor private struct RootCheckFixture {
    let base: URL
    let root: AccessRootID
    let mounts: RootCheckMounts
    let monitor: AccessMonitor
    let codec: RootCheckBookmarks
    init(sourceExists: (@Sendable (URL, RootCheckBookmarks) throws -> Bool)? = nil) async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("broken.jpg"))
        let codec = RootCheckBookmarks()
        self.codec = codec
        let files = try FileAccess(scope: codec, bookmarks: codec,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "T229-root-check",
            bookmarkVolume: { _ in AccessProbeVolume(uuid: "111", url: nil, name: "Disk") },
            resolvedVolumeUUID: { _ in "111" })
        root = try await files.grant(folder: folder)
        mounts = RootCheckMounts()
        let services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(),
                scheduler: DispatchWatchScheduler()), mounts: mounts)
        if let sourceExists {
            monitor = AccessMonitor(files: files, mounts: mounts, sourceExists: { try sourceExists($0, codec) })
        } else {
            monitor = services.monitor
        }
        self.base = base
        await monitor.register(root)
        #expect(monitor.state.snapshot(for: root)?.availability == .readable)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
@MainActor private func rootCheckWait(_ predicate: @MainActor () async -> Bool) async throws {
    while !(await predicate()) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await predicate())
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229FixDecodeFailuresNeverStartRootChecks() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let before = await f.mounts.enumerations
    let stamp = f.monitor.state.stamp(for: f.root)
    let failures: [any Error] = [ImageLoadError(.corruptImage), ImageLoadError(.unsupportedFormat),
                                 ImageDecodeError.unreadableImage, ImageDecodeError.budgetExceeded]
    for _ in 0..<5 {
        for failure in failures { await f.monitor.reportReadFailure(f.root, from: stamp, error: failure) }
    }
    #expect(await f.mounts.enumerations == before)
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229FixConcurrentAccessFailuresShareOneRootCheck() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let before = await f.mounts.enumerations
    let stamp = f.monitor.state.stamp(for: f.root)
    await f.mounts.pauseEnumeration()
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    let reports = (0..<20).map { _ in
        Task { @MainActor in await f.monitor.reportReadFailure(f.root, from: stamp, error: denied) }
    }
    try await rootCheckWait { await f.mounts.paused }
    // Negative observation only after the first root check is known to be held.
    try await Task.sleep(for: .milliseconds(200))
    await f.mounts.release()
    for report in reports { await report.value }
    #expect(await f.mounts.enumerations - before == 1)
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229FixRepeatedActivationChecksEachRootOnce() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let before = await f.mounts.enumerations
    var completed = false
    let readiness = f.monitor.observeReadiness { if $0 == f.root { completed = true } }
    defer { f.monitor.removeReadinessObserver(readiness) }
    await f.mounts.pauseEnumeration()
    for _ in 0..<5 {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    }
    try await rootCheckWait { await f.mounts.paused }
    // Observe duplicate activation while the positive check remains held.
    try await Task.sleep(for: .milliseconds(200))
    await f.mounts.release()
    try await rootCheckWait { completed }
    #expect(await f.mounts.enumerations - before == 1)
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
}

// Audit M4: the wake path shares the foreground recheck.
@MainActor @Test(.timeLimit(.minutes(3))) func t229FixWakeRechecksSavedRootsOnce() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let before = await f.mounts.enumerations
    var completed = false
    let readiness = f.monitor.observeReadiness { if $0 == f.root { completed = true } }
    defer { f.monitor.removeReadinessObserver(readiness) }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    try await rootCheckWait { completed }
    // After completion, watch for an unwanted duplicate root check.
    try await Task.sleep(for: .milliseconds(200))
    #expect(await f.mounts.enumerations - before == 1)
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
}

// Audit opus M7 (round 2): a missing source is access evidence, not content.
// ENOENT maps to sourceChanged; a decoder failure on a file that no longer
// exists can't be told from damage. Each starts exactly one root check; a
// damaged file that is still there starts none.
@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix2MissingSourceFailuresStartOneRootCheck() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let stamp = f.monitor.state.stamp(for: f.root)
    let gone = f.base.appendingPathComponent("Root/gone.jpg")
    let enoent = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    let missing: [(any Error, URL?)] = [(ImageLoadError(.sourceChanged), nil), (ImageLoadError(.sourceChanged), gone),
        (ImageLoadError(.corruptImage), gone), (ImageLoadError(.unsupportedFormat), gone),
        (ImageDecodeError.unreadableImage, gone), (enoent, gone)]
    for (failure, file) in missing {
        let before = await f.mounts.enumerations
        await f.monitor.reportReadFailure(f.root, from: stamp, error: failure, file: file)
        #expect(await f.mounts.enumerations - before == 1, "\(failure)")
    }
    let broken = f.base.appendingPathComponent("Root/broken.jpg")
    let before = await f.mounts.enumerations
    for failure: any Error in [ImageLoadError(.corruptImage), ImageLoadError(.unsupportedFormat), ImageDecodeError.unreadableImage,
                               ImageLoadError(.resourceLimit), ImageLoadError(.cancelled)] {
        await f.monitor.reportReadFailure(f.root, from: stamp, error: failure, file: broken)
    }
    #expect(await f.mounts.enumerations == before)
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
}

// A stalled filesystem boundary must not occupy the UI actor. A wrong MainActor
// call returns immediately so ranOnMain fails without deadlocking that actor.
private final class RootCheckProbeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var total = 0
    private var blocked = 0
    private var onMain = false
    private var unscoped = false
    var calls: Int { condition.lock(); defer { condition.unlock() }; return total }
    var waiting: Bool { condition.lock(); defer { condition.unlock() }; return blocked > 0 && !released }
    var ranOnMain: Bool { condition.lock(); defer { condition.unlock() }; return onMain }
    var ranUnscoped: Bool { condition.lock(); defer { condition.unlock() }; return unscoped }
    func probe(_ url: URL, codec: RootCheckBookmarks) -> Bool {
        condition.lock(); defer { condition.unlock() }
        total += 1; blocked += 1
        onMain = onMain || Thread.isMainThread
        unscoped = unscoped || codec.activeScopes == 0
        // Keep a correct background probe held until explicit release.
        // The test already asserts !ranOnMain; never block the UI on a regression.
        while !released && !Thread.isMainThread { condition.wait() }
        blocked -= 1
        return false
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [Int(EPERM), Int(EACCES), Int(EIO)])
func t229Fix3DeniedOrIndeterminateSourceIsNotMissing(_ code: Int) async throws {
    let f = try await RootCheckFixture(sourceExists: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: code) })
    defer { f.remove() }
    let broken = f.base.appendingPathComponent("Root/broken.jpg")
    #expect(FileManager.default.fileExists(atPath: broken.path))
    let before = await f.mounts.enumerations
    let snapshot = f.monitor.state.snapshot(for: f.root)
    for failure: any Error in [ImageLoadError(.corruptImage), ImageLoadError(.unsupportedFormat), ImageDecodeError.unreadableImage] {
        await f.monitor.reportReadFailure(f.root, from: f.monitor.state.stamp(for: f.root), error: failure, file: broken)
    }
    #expect(await f.mounts.enumerations == before)
    #expect(f.monitor.state.snapshot(for: f.root) == snapshot)
    #expect(f.codec.activeScopes == 0)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [false, true])
func t229Fix3BlockedSourceProbeIsScopedResponsiveAndRejectsLateResult(_ stale: Bool) async throws {
    let gate = RootCheckProbeGate()
    let f = try await RootCheckFixture(sourceExists: { gate.probe($0, codec: $1) })
    defer { f.remove() }
    let started = StartedTasks()
    try await withAsyncTeardown {
        let stamp = f.monitor.state.stamp(for: f.root)
        let before = await f.mounts.enumerations
        let report = Task { @MainActor in
            await f.monitor.reportReadFailure(f.root, from: stamp, error: ImageLoadError(.corruptImage),
                                             file: f.base.appendingPathComponent("Root/broken.jpg"))
        }
        started.track(report)
        try await rootCheckWait { gate.calls > 0 }
        // Reaching here on MainActor while the probe waits is the heartbeat.
        #expect(gate.waiting)
        #expect(!gate.ranOnMain)
        #expect(!gate.ranUnscoped)
        #expect(f.codec.activeScopes > 0)
        if stale { f.monitor.state.reauthorize(f.root, volumeUUID: "111") }
        else { report.cancel() }
        let expected = f.monitor.state.snapshot(for: f.root)
        await f.mounts.disconnect()
        gate.release()
        await report.value
        #expect(f.monitor.state.snapshot(for: f.root) == expected)
        #expect(await f.mounts.enumerations == before)
        #expect(f.codec.activeScopes == 0)
    } teardown: {
        started.cancelAll()
        await started.awaitAll { gate.release() }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix3StaleAndCancelledReportsNeverProbe() async throws {
    let gate = RootCheckProbeGate(); gate.release()
    let f = try await RootCheckFixture(sourceExists: { gate.probe($0, codec: $1) })
    defer { f.remove() }
    let stamp = f.monitor.state.stamp(for: f.root)
    f.monitor.state.reauthorize(f.root, volumeUUID: "111")
    let file = f.base.appendingPathComponent("Root/broken.jpg")
    await f.monitor.reportReadFailure(f.root, from: stamp, error: ImageLoadError(.corruptImage), file: file)
    let cancelled = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        await f.monitor.reportReadFailure(f.root, from: f.monitor.state.stamp(for: f.root),
                                         error: ImageLoadError(.corruptImage), file: file)
    }
    await cancelled.value
    #expect(gate.calls == 0)
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix3ConcurrentSourceReportsCoalesceAndCancellationIsPerCaller() async throws {
    let gate = RootCheckProbeGate()
    let f = try await RootCheckFixture(sourceExists: { gate.probe($0, codec: $1) })
    let started = StartedTasks()
    try await withAsyncTeardown {
        let stamp = f.monitor.state.stamp(for: f.root)
        let before = await f.mounts.enumerations
        await f.mounts.pauseEnumeration()
        let reports = (0..<12).map { _ in Task { @MainActor in
            await f.monitor.reportReadFailure(f.root, from: stamp, error: ImageLoadError(.corruptImage),
                                             file: f.base.appendingPathComponent("Root/broken.jpg"))
        } }
        reports.forEach { started.track($0) }
        try await rootCheckWait { gate.calls > 0 }
        // The probe is held; this window only observes unwanted duplicate probes.
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.waiting)
        #expect(gate.calls == 1)
        reports[0].cancel()
        gate.release()
        try await rootCheckWait { await f.mounts.paused }
        await f.mounts.disconnect()
        await f.mounts.release()
        for report in reports { await report.value }
        #expect(await f.mounts.enumerations - before == 1)
        #expect(f.monitor.state.snapshot(for: f.root)?.availability == .lost(.diskNotConnected))
        #expect(f.codec.activeScopes == 0)
    } teardown: {
        gate.release(); started.cancelAll()
        await started.awaitAll { await f.mounts.release() }
        f.remove(); await f.mounts.release()
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229Fix3ContentProbeDoesNotSwallowOtherSourcesOrAccessEvidence() async throws {
    let gate = RootCheckProbeGate()
    let f = try await RootCheckFixture(sourceExists: { url, codec in
        if url.lastPathComponent == "broken.jpg" { _ = gate.probe(url, codec: codec); return true }
        return false
    })
    defer { f.remove() }
    let started = StartedTasks()
    try await withAsyncTeardown {
        let stamp = f.monitor.state.stamp(for: f.root)
        let before = await f.mounts.enumerations
        let present = Task { @MainActor in
            await f.monitor.reportReadFailure(f.root, from: stamp, error: ImageLoadError(.corruptImage),
                                             file: f.base.appendingPathComponent("Root/broken.jpg"))
        }
        started.track(present)
        try await rootCheckWait { gate.calls > 0 }
        #expect(gate.waiting)
        // A different missing source and explicit access evidence still reach root checks.
        await f.monitor.reportReadFailure(f.root, from: stamp, error: ImageLoadError(.unsupportedFormat),
                                         file: f.base.appendingPathComponent("Root/gone.jpg"))
        await f.monitor.reportReadFailure(f.root, from: stamp, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        #expect(await f.mounts.enumerations - before == 2)
        gate.release()
        await present.value
        #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
        #expect(f.codec.activeScopes == 0)
    } teardown: {
        started.cancelAll()
        await started.awaitAll { gate.release() }
    }
}


// POSIX denial only: genuine sandbox/TCC revocation is device-owned evidence.
@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["foreground", "wake", "reader"])
func t230RealRootDenialOnForegroundAndWakeInvalidatesHeldPermit(_ event: String) async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let folder = f.base.appendingPathComponent("Root")
    let files = f.monitor.files
    let lease = try await files.acquire(.root(f.root, file: folder))
    let permit = try #require(f.monitor.state.permit(for: f.root))
    let stamp = f.monitor.state.stamp(for: f.root)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    #expect(throws: (any Error).self) { try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
    if event == "foreground" {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    } else if event == "wake" {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    } else {
        await f.monitor.reportReadFailure(f.root, from: stamp,
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
    }
    try await rootCheckWait { f.monitor.state.snapshot(for: f.root)?.availability != .readable }
    #expect(f.monitor.state.snapshot(for: f.root)?.availability == .lost(.accessExpired))
    #expect(f.monitor.state.snapshot(for: f.root)?.counter == stamp.counter + 1)
    #expect(!permit.isCurrent && !f.monitor.state.mayDeliver(stamp))
    #expect(f.monitor.state.permit(for: f.root) == nil)
    await files.release(lease)
    #expect(f.codec.activeScopes == 0)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func t230ReaderSourcesVerifyRootRatherThanUnreadableChild() async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let folder = f.base.appendingPathComponent("Root")
    let child = folder.appendingPathComponent("broken.jpg")
    let subfolder = folder.appendingPathComponent("Private")
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    for url in [child, subfolder] {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: child.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: subfolder.path)
    }
    let stamp = f.monitor.state.stamp(for: f.root)
    let permit = try #require(f.monitor.state.permit(for: f.root))
    // Every reader reports into this common boundary; neither child proves root loss.
    for _ in ["scan", "thumbnail", "viewer", "Inspector", "watcher"] {
        for url in [child, subfolder] {
            await f.monitor.reportReadFailure(f.root, from: stamp,
                error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), file: url)
            #expect(f.monitor.state.snapshot(for: f.root)?.availability == .readable)
            #expect(f.monitor.state.stamp(for: f.root) == stamp && permit.isCurrent)
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: [false, true])
func t230ConcurrentReaderForegroundWakeShareOneLossEpisode(_ supersede: Bool) async throws {
    let f = try await RootCheckFixture(); defer { f.remove() }
    let folder = f.base.appendingPathComponent("Root")
    let stamp = f.monitor.state.stamp(for: f.root)
    let permit = try #require(f.monitor.state.permit(for: f.root))
    var lossCounters: [UInt64] = []
    let observation = f.monitor.state.observe { change in
        if case .lost(let root, let counter) = change, root == f.root { lossCounters.append(counter) }
    }
    defer { f.monitor.state.removeObserver(observation) }
    await f.mounts.pauseEnumeration()
    let report = Task { @MainActor in
        await f.monitor.reportReadFailure(f.root, from: stamp,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
    }
    try await rootCheckWait { await f.mounts.paused }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    for _ in 0..<3 {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    }
    // Notifications may enter before or after the held reader check. Either
    // ordering must preserve one loss episode; Task.yield is not an entry proof.
    if supersede { f.monitor.state.reauthorize(f.root, volumeUUID: "111") }
    await f.mounts.release()
    await report.value
    if supersede {
        // The lifecycle check may legitimately capture the new counter. Only this
        // old report is constrained not to revoke newer authority; existing stale
        // reader tests isolate that guarantee without a fresh lifecycle request.
        #expect(!permit.isCurrent && !f.monitor.state.mayDeliver(stamp))
    } else {
        try await rootCheckWait { f.monitor.state.snapshot(for: f.root)?.availability != .readable }
        #expect(f.monitor.state.snapshot(for: f.root)?.availability == .lost(.accessExpired))
        #expect(f.monitor.state.snapshot(for: f.root)?.counter == stamp.counter + 1)
        #expect(lossCounters == [stamp.counter + 1])
        let lost = f.monitor.state.snapshot(for: f.root)
        await f.monitor.reportReadFailure(f.root, from: stamp,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        #expect(f.monitor.state.snapshot(for: f.root) == lost)
        #expect(lossCounters == [stamp.counter + 1])
        #expect(!permit.isCurrent)
    }
}
