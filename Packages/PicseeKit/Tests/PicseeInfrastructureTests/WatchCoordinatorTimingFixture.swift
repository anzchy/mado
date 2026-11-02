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
    let clock = FakeWatchClock()
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

    /// Buffered signals cannot be missed if completion precedes registration. Cancellation terminates the
    /// AsyncStream wait and the watchdog sleep; the group always drains. Wall time is only a failure bound,
    /// never a clock input or a polling cadence. A failed wait throws and stops the caller immediately.
    func waitForEnd(generation: UInt64, at time: Int) async throws {
        let stream = signal.stream
        let actual = try await withThrowingTaskGroup(of: UInt64.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await value in stream { return value }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TimingWaitExpired(generation: generation, time: time)
            }
            return try await group.next()!
        }
        try #require(actual == generation, "t=\(time) expected scan end \(generation), got \(actual)")
    }
}

private struct TimingWaitExpired: Error, CustomStringConvertible {
    let generation: UInt64
    let time: Int
    var description: String { "t=\(time) scan \(generation) did not end within the 5 s watchdog" }
}
