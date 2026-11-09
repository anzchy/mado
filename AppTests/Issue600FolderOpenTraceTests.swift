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

@Test @MainActor
func issue600SuccessfulTraceIsOrderedAndDefaultStillScans() async throws {
    var results: [Set<String>] = []
    for recording in [true, false] {
        let rig = try FolderOpen600Rig()
        defer { rig.remove() }
        let controller = rig.controller()
        let window = try #require(controller.window)
        defer { window.close() }
        let captured = FolderOpen600Events()
        if recording { controller.folderOpenStageObserver = { captured.append($0) } }
        let before = ContinuousClock.now
        controller.openGrantedFolder(rig.folder)
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
                "scan.services", "readContext", "recovery", "coordinator.begin"]
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
