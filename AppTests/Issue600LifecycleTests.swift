import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Motion600L: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Volume-backed bookmarks so the monitor can lose the root on an unmount, as in LostAccessWindowTests.
private struct Bookmarks600L: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}

private actor Mounts600L: DiskMountPort {
    private var continuation: AsyncStream<DiskMountEvent>.Continuation?
    private var volumes = [AccessProbeVolume(uuid: "600", url: URL(fileURLWithPath: "/"), name: "Disk")]
    func mountedVolumes() -> [AccessProbeVolume] { volumes }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { continuation = $0 } }
    func unmount() {
        let volume = AccessProbeVolume(uuid: "600", url: nil, name: "Disk")
        volumes.removeAll()
        continuation?.yield(.unmounted(volume))
    }
}

/// One controller over a temporary folder of three images, recording every folder-open lifecycle event.
@MainActor private final class Lifecycle600Rig {
    let base: URL, folder: URL, other: URL
    let files: FileAccess, services: AccessServices, mounts = Mounts600L()
    let controller: CanvasWindowController
    var events: [String] = []
    var onEvent: (String) -> Void = { _ in }

    init() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("life600-\(UUID())")
        folder = base.appendingPathComponent("folder"); other = base.appendingPathComponent("other")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        let data = try Data(contentsOf: asset)
        for index in 0..<3 { try data.write(to: folder.appendingPathComponent("\(index).png")) }
        try data.write(to: other.appendingPathComponent("o.png"))
        let adapter = Bookmarks600L()
        files = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue600-lifecycle",
            bookmarkVolume: { _ in AccessProbeVolume(uuid: "600", url: nil, name: "Disk") })
        services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()),
            mounts: mounts)
        let services = services
        controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { services }, motionPolicy: MotionPolicy(source: Motion600L()))
        controller.folderOpenLifecycleObserver = { [unowned self] event in
            events.append(event.description)
            onEvent(event.description)
        }
    }
    var complete: Bool {
        controller.session.folderScan?.sourceSnapshot?.isComplete == true && controller.session.folderScan?.isScanning == false
    }
    /// Waits up to 20 s of wall time; these tests assert what happened, not how fast.
    func until(_ condition: () -> Bool) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            if ContinuousClock.now >= end { return false }
            controller.window?.update()
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
    func remove() { controller.window?.close(); try? FileManager.default.removeItem(at: base) }
}

/// i600-fix1 F2: an open that runs through records its grant task, then its scan task starting, handing the folder to
/// the scanner and finishing, in that order.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600LifecycleRecordsAnOpenFromGrantToScanCompletion() async throws {
    let rig = try Lifecycle600Rig()
    defer { rig.remove() }
    rig.controller.openGrantedFolder(rig.folder)
    let done = try await rig.until { rig.complete && rig.events.contains("scan#2 completed") }
    #expect(done, "events: \(rig.events)")
    #expect(rig.events == ["grant#1 started", "grant#1 completed", "scan#2 started", "scan#2 scan-began", "scan#2 completed"])
}

/// F2 task-cancelled: a second open while the first open's scan task waits for its services cancels that task.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600LifecycleNamesAScanTaskCancelledByALaterOpen() async throws {
    let rig = try Lifecycle600Rig()
    defer { rig.remove() }
    rig.onEvent = { event in if event == "scan#2 started" { rig.controller.openGrantedFolder(rig.other) } }
    rig.controller.openGrantedFolder(rig.folder)
    let done = try await rig.until { rig.events.contains("scan#2 rejected task-cancelled") }
    #expect(done, "events: \(rig.events)")
    #expect(!rig.events.contains("scan#2 scan-began"), "events: \(rig.events)")
}

/// F2 authority-rejected: input that arrives after the scan began takes the window over, so the scan's first
/// presentation is refused.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600LifecycleNamesAScanRefusedByLaterInput() async throws {
    let rig = try Lifecycle600Rig()
    defer { rig.remove() }
    rig.onEvent = { event in if event == "scan#2 scan-began" { rig.controller.openInput([]) } }
    rig.controller.openGrantedFolder(rig.folder)
    let done = try await rig.until { rig.events.contains("scan#2 rejected authority-rejected") }
    #expect(done, "events: \(rig.events)")
}

/// F2 waiting-access: opening a folder whose root is in Lost Access shows the waiting page and starts no scan task.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600LifecycleNamesAnOpenWhoseRootIsLost() async throws {
    let rig = try Lifecycle600Rig()
    defer { rig.remove() }
    let root = try await rig.files.grant(folder: rig.folder)
    rig.controller.browseRecoveredFolder(rig.folder, rootID: root)
    #expect(try await rig.until { rig.complete }, "events: \(rig.events)")
    rig.services.monitor.state.register(root, volumeUUID: "600")
    await rig.mounts.unmount()
    #expect(try await rig.until { rig.services.monitor.state.snapshot(for: root)?.availability == .lost(.diskNotConnected) })
    rig.controller.browseRecoveredFolder(rig.folder, rootID: root)
    #expect(rig.events.last == "scan#2 rejected waiting-access", "events: \(rig.events)")
}
