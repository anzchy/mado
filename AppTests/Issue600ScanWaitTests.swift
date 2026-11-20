import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// A clock the test moves. Each `pause` adds its next step (a step over the threshold is a stall). With `realTime`, the clock
/// is the real one plus the steps taken: a step jumps it and yields once, and later looks sleep 5 ms of real time.
@MainActor private final class Steps600 {
    let base = ContinuousClock.now
    let realTime: Bool
    var offset = Duration.zero
    var steps: [Duration]
    var pauses = 0
    init(_ steps: [Duration], realTime: Bool = false) { self.steps = steps; self.realTime = realTime }
    func wait() -> ActiveTimeWait {
        var wait = ActiveTimeWait()
        wait.now = { [self] in (realTime ? ContinuousClock.now : base).advanced(by: offset) }
        wait.pause = { [self] in
            pauses += 1
            if realTime {
                if steps.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
                else { offset += steps.removeFirst(); await Task.yield() }
            } else {
                offset += steps.isEmpty ? .milliseconds(5) : steps.removeFirst()
            }
        }
        return wait
    }
}

/// #600 (CI runs 42369028897, 42728233488, 43163508262, 44714991399): the main actor stalled after the open, so the
/// two-second deadline passed while neither the scan nor the test loop could run. A stall is not charged to the budget.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600StallIsNotChargedToTheActiveBudget() async throws {
    let steps = Steps600([.milliseconds(2_500)])
    let report = try await steps.wait().until { steps.pauses >= 3 }
    #expect(report.held, "a 2.5 s stall must not end a 2 s budget: \(report)")
    #expect(report.stalls == [.milliseconds(2_500)], "\(report)")
    #expect(report.active == .milliseconds(10), "\(report)")
}

/// The budget still ends a wait that never holds after 2 s of active time, and names no stall.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600ActiveBudgetStillEndsAWaitThatNeverHolds() async throws {
    let steps = Steps600([])
    let report = try await steps.wait().until { false }
    #expect(!report.held)
    #expect(report.polls == 400, "\(report)")
    #expect(report.active == .seconds(2) && report.stalls.isEmpty, "\(report)")
}

/// A process that only ever stalls still ends at the wall cap, with every stall named.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600WallCapEndsAWaitThatOnlyStalls() async throws {
    let steps = Steps600(Array(repeating: .milliseconds(300), count: 200))
    let report = try await steps.wait().until { false }
    #expect(!report.held)
    // 67 stalls of 300 ms pass the 20 s cap (20.1 s).
    #expect(report.wall == .milliseconds(20_100) && report.active == .zero, "\(report)")
    #expect(report.stalls.count == 67, "\(report)")
}

/// Forced ordering of the CI signature with the real controller and the real (non-legacy) scanner: open the symlinked
/// folder, then stall the clock past the deadline before the scan's main-actor hops run. The wait must still see the
/// scan complete; with a wall-clock deadline it reads `scanExists=false` exactly as on CI.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue600StalledDeadlineStillSeesTheSymlinkScanComplete() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("stall600-\(UUID())")
    defer { try? fm.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual"), symlink = base.appendingPathComponent("symlink")
    try fm.createDirectory(at: actual, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: symlink, withDestinationURL: actual)
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let data = try Data(contentsOf: asset)
    for index in 0..<3 { try data.write(to: actual.appendingPathComponent("\(index).png")) }
    let system = SystemSecurityScope()
    let access = try FileAccess(scope: system, bookmarks: system,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue600")
    let services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: Motion600()))
    let window = try #require(controller.window)
    defer { window.close() }
    controller.openGrantedFolder(symlink)
    // The open has only queued its work: nothing scans before the first look.
    #expect(controller.session.folderScan == nil)
    // The first look's pause is a 2.5 s stall that lets the main actor run only once (a yield): the deadline passes
    // before the scan's remaining main-actor hops can run. Later looks sleep 5 ms of real time.
    let report = try await Steps600([.milliseconds(2_500)], realTime: true).wait().until(between: { window.update() }) {
        controller.session.folderScan?.sourceSnapshot?.isComplete == true &&
            controller.session.folderScan?.isScanning == false && controller.gridSearchAvailable
    }
    let scan = controller.session.folderScan
    #expect(report.held, "scanExists=\(scan != nil), scanning=\(scan?.isScanning ?? false): \(report)")
    #expect(report.stalls.count == 1 && report.stalls[0] >= .milliseconds(2_500), "\(report)")
    #expect(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == ["0.png", "1.png", "2.png"])
}

@MainActor private final class Motion600: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}
