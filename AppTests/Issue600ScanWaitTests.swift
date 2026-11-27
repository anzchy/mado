import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// A clock the test moves. Each `pause` adds its next step, a process-wide suspension: the heartbeat is silent for the
/// whole step (i600-fix1: only such a gap is discounted). With `realTime`, the clock is the real one plus the steps
/// taken: a step jumps it, runs `onStep` and yields once, and later looks sleep 5 ms of real time.
@MainActor private final class Steps600 {
    let base = ContinuousClock.now
    let realTime: Bool
    var offset = Duration.zero
    var steps: [Duration]
    var silent: [(ContinuousClock.Instant, ContinuousClock.Instant)] = []
    var pauses = 0
    var onStep: () -> Void = {}
    init(_ steps: [Duration], realTime: Bool = false) { self.steps = steps; self.realTime = realTime }
    func wait() -> ActiveTimeWait {
        var wait = ActiveTimeWait()
        wait.now = { [self] in (realTime ? ContinuousClock.now : base).advanced(by: offset) }
        wait.pause = { [self] in
            pauses += 1
            let from = (realTime ? ContinuousClock.now : base).advanced(by: offset)
            if realTime {
                if steps.isEmpty { try await Task.sleep(for: .milliseconds(5)); return }
                offset += steps.removeFirst()
                silent.append((from, ContinuousClock.now.advanced(by: offset)))
                onStep()
                await Task.yield()
            } else if steps.isEmpty {
                offset += .milliseconds(5)
            } else {
                offset += steps.removeFirst()
                silent.append((from, base.advanced(by: offset)))
            }
        }
        wait.heartbeatSilence = { [self] from, to in
            silent.reduce(Duration.zero) { sum, gap in
                let low = max(gap.0, from), high = min(gap.1, to)
                return low < high ? sum + low.duration(to: high) : sum
            }
        }
        return wait
    }
}

/// Holds the real scan until the synthetic stall has passed the deadline (gpt M1: the order is forced, not hoped for).
private final class Gate600: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true; defer { waiters = [] }; return waiters
        }
        for waiter in resumed { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation); return false
            }
            if now { continuation.resume() }
        }
    }
}

/// The real FolderBrowser behind the gate.
private struct GatedBrowser600: FolderScanning {
    let gate: Gate600
    let entered = Gate600()
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        entered.open()
        await gate.wait()
        try await FolderBrowser().scan(in: folder, root: root, options: options, emit: emit)
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

/// Forced ordering of the CI signature with the real controller and the real (non-legacy) FolderBrowser: open the
/// symlinked folder, then stall the clock past the deadline while a gate holds the scan, and only then let it run. The
/// wait must still see the scan complete. What this proves: a process-wide stall that passes a wall-clock deadline
/// before the scan finishes fails a wall-clock wait (the scan is incomplete at the stall) and not this one. It does
/// not prove that the CI stall was process-wide; the heartbeat in the report says that on CI.
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
    let gate = Gate600()
    controller.folderScanningOverride = GatedBrowser600(gate: gate)
    controller.openGrantedFolder(symlink)
    // The open has only queued its work: nothing scans before the first look.
    #expect(controller.session.folderScan == nil)
    // The first look's pause is a 2.5 s process-wide stall; the gate opens only after it, so the scan cannot have
    // completed before the deadline passed. Later looks sleep 5 ms of real time.
    let steps = Steps600([.milliseconds(2_500)], realTime: true)
    #expect(!steps.realTime, "the real scan's scheduling delay must not consume the synthetic active budget")
    var completeAtStall: Bool?
    steps.onStep = {
        completeAtStall = controller.session.folderScan?.sourceSnapshot?.isComplete == true
        gate.open()
    }
    let report = try await steps.wait().until(between: { window.update() }) {
        controller.session.folderScan?.sourceSnapshot?.isComplete == true &&
            controller.session.folderScan?.isScanning == false && controller.gridSearchAvailable
    }
    #expect(completeAtStall == false, "the scan must still be held when the deadline passes: \(report)")
    let scan = controller.session.folderScan
    #expect(report.held, "scanExists=\(scan != nil), scanning=\(scan?.isScanning ?? false): \(report)")
    #expect(report.stalls.count >= 1 && report.stalls.first.map { $0 >= .milliseconds(2_500) } == true, "\(report)")
    #expect(Set(scan?.sourceSnapshot?.navigationEntries.map { $0.url.lastPathComponent } ?? []) == ["0.png", "1.png", "2.png"])
}

@MainActor private final class Motion600: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}
