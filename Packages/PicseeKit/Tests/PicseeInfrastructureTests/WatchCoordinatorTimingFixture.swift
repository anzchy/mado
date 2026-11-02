import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

/// No files, bookmarks, FSEvents, or scan scheduling delays. Only WatchHub and the coordinator are real.
@MainActor final class TimingCoordinatorFixture {
    let root = URL(fileURLWithPath: "/picsee-watch-timing-fixture")
    let rootID = AccessRootID()
    var folder: URL { root.appendingPathComponent("F") }
    let clock = TimingWatchClock()
    let source = FakeFolderEventSource()
    let scanner: TimingFolderScanner
    let trace = TimingScanTrace()
    let coordinator: FolderScanCoordinator

    init() {
        let access = TimingAccess(root: root, rootID: rootID)
        scanner = TimingFolderScanner(root: ItemIdentityRoot(id: rootID, url: root))
        scanner.add("a.png")
        let hub = WatchHub(access: access, source: source, scheduler: clock)
        coordinator = FolderScanCoordinator(access: access, scanner: scanner, trace: trace, watcher: hub)
    }
    func names() -> [String] { coordinator.snapshot?.entries.map(\.url.lastPathComponent) ?? [] }
}

private struct TimingAccess: AccessLeasing {
    let root: URL
    let rootID: AccessRootID
    func acquire(_ request: AccessRequest) async throws -> AccessLease { AccessLease(url: root, rootID: rootID) }
    func release(_ lease: AccessLease) async { }
}

/// The driver writes synchronously; the scan reads one immutable copy under the same lock.
final class TimingFolderScanner: FolderScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let root: ItemIdentityRoot
    private var stored: [FolderEntry] = []
    init(root: ItemIdentityRoot) { self.root = root }
    var entries: [FolderEntry] { lock.withLock { stored } }
    func add(_ name: String) {
        let entry = FolderEntry(url: root.url.appendingPathComponent("F/" + name), root: root)
        lock.withLock { stored.append(entry) }
    }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try await emit(entries)
    }
}

@MainActor final class TimingScanTrace: FolderScanTracing {
    private let signal = AsyncStream<UInt64>.makeStream()
    private(set) var begins: [UInt64] = []
    private(set) var ends: [(outcome: FolderScanOutcome, generation: UInt64)] = []
    func begin(generation: UInt64, folderURL: URL) { begins.append(generation) }
    func firstBatch(count: Int, generation: UInt64) { }
    func complete(count: Int, generation: UInt64) { }
    func end(outcome: FolderScanOutcome, generation: UInt64) {
        ends.append((outcome, generation))
        signal.continuation.yield(generation)
    }

    /// Buffered completions cannot be missed. AsyncStream terminates on task cancellation; the test's
    /// time limit is the only wall-clock bound, so MainActor queueing cannot expire a shorter watchdog.
    /// A cancelled wait throws once with its fake-clock context and stops the driver immediately.
    func waitForEnd(generation: UInt64, at time: Int) async throws {
        for await actual in signal.stream {
            try #require(actual == generation, "t=\(time) expected scan end \(generation), got \(actual)")
            return
        }
        let error = TimingWaitCancelled(generation: generation, time: time)
        // Swift Testing reports the time-limit issue and discards the cancelled body's thrown error.
        print("WatchCoordinatorTimingTests: \(error)")
        throw error
    }
}

private struct TimingWaitCancelled: Error, CustomStringConvertible {
    let generation: UInt64
    let time: Int
    var description: String { "t=\(time) scan \(generation) completion wait cancelled by the test time limit or task cancellation" }
}

/// Counts actual scheduler deliveries, including unexpected late callbacks. A zero-delivery advance
/// cannot enqueue coordinator work, so the quiet tail can be checked synchronously without polling.
final class TimingWatchClock: WatchScheduling, @unchecked Sendable {
    private let clock = FakeWatchClock()
    private let lock = NSLock()
    private var deliveries = 0
    var deliveredCount: Int { lock.withLock { deliveries } }
    var nowMilliseconds: Int { clock.nowMilliseconds }
    func schedule(afterMilliseconds: Int, _ action: @escaping @Sendable () -> Void) -> any WatchCancellable {
        clock.schedule(afterMilliseconds: afterMilliseconds) { [self] in
            lock.withLock { deliveries += 1 }
            action()
        }
    }
    @discardableResult func advance(to time: Int) -> Int {
        let before = deliveredCount
        clock.advance(to: time)
        return deliveredCount - before
    }
}
