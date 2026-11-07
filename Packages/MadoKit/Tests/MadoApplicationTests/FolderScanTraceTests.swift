import Foundation
import Testing
import MadoCore
import MadoApplication

private enum FolderTraceEvent: Equatable {
    case begin(UInt64, URL), firstBatch(Int, UInt64), complete(Int, UInt64), end(FolderScanOutcome, UInt64)
}
@MainActor private final class FolderTraceRecorder: FolderScanTracing {
    var events: [FolderTraceEvent] = []
    func begin(generation: UInt64, folderURL: URL) { events.append(.begin(generation, folderURL)) }
    func firstBatch(count: Int, generation: UInt64) { events.append(.firstBatch(count, generation)) }
    func complete(count: Int, generation: UInt64) { events.append(.complete(count, generation)) }
    func end(outcome: FolderScanOutcome, generation: UInt64) { events.append(.end(outcome, generation)) }
}
@MainActor private struct FolderTraceFixture {
    let root = URL(fileURLWithPath: "/folder-trace-tests")
    let id = AccessRootID()
    let trace: FolderTraceRecorder
    let scanner: FolderScanControlledScanner
    let access: FolderScanCountingLeases
    let coordinator: FolderScanCoordinator
    init(fails: Bool = false, holdsAcquire: Bool = false) {
        let root = URL(fileURLWithPath: "/folder-trace-tests")
        let trace = FolderTraceRecorder(), scanner = FolderScanControlledScanner()
        let access = FolderScanCountingLeases(root: root, fails: fails, holdsAcquire: holdsAcquire)
        self.trace = trace; self.scanner = scanner; self.access = access
        coordinator = FolderScanCoordinator(access: access, scanner: scanner, trace: trace)
    }
    var folder: URL { root.appendingPathComponent("A") }
}

@Test @MainActor func folderScanTraceBeginsBeforeAcquire() async throws {
    let fixture = FolderTraceFixture(holdsAcquire: true)
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    #expect(fixture.trace.events == [.begin(1, fixture.folder)])
    #expect(fixture.coordinator.snapshot == nil)
    await fixture.access.waitForHeldAcquisition()
    fixture.coordinator.cancel()
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .end(.cancelled, 1)])
    await fixture.access.resumeAcquisition()
    try await task.value
    #expect(await fixture.scanner.startedCount == 0)
    #expect(await fixture.access.balance == [1, 1])
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .end(.cancelled, 1)])
}

@Test(arguments: ["complete", "cancel", "end", "failed"])
@MainActor func folderScanTraceLifecycle(ending: String) async throws {
    let fixture = FolderTraceFixture(), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver([])
    #expect(fixture.trace.events == [.begin(1, fixture.folder)])
    try await fixture.scanner.deliver(["img10.png", "img2.png"])
    try await fixture.scanner.deliver(["img1.png"])
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .firstBatch(2, 1)])
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img1.png", "img2.png", "img10.png"])
    if ending == "cancel" { coordinator.cancel() }
    if ending == "end" { coordinator.end() }
    if ending == "cancel" || ending == "end" {
        #expect(fixture.trace.events == [.begin(1, fixture.folder), .firstBatch(2, 1), .end(.cancelled, 1)])
        #expect(await fixture.access.balance == [1, 0])
    }
    await fixture.scanner.finish(failing: ending == "failed")
    if ending == "failed" {
        await #expect(throws: FolderScanTestError.expected) { try await task.value }
        #expect(fixture.trace.events == [.begin(1, fixture.folder), .firstBatch(2, 1), .end(.failed, 1)])
        #expect(coordinator.failure is FolderScanTestError)
    } else { try await task.value }
    if ending == "complete" {
        #expect(fixture.trace.events == [.begin(1, fixture.folder), .firstBatch(2, 1), .complete(3, 1), .end(.complete, 1)])
        #expect(coordinator.snapshot?.isComplete == true)
    }
    #expect(await fixture.access.balance == [1, 1])
    let events = fixture.trace.events
    coordinator.end(); coordinator.cancel()
    #expect(fixture.trace.events == events)
}

@Test(arguments: ["batch", "completion", "error"])
@MainActor func folderScanTraceRejectsLateEvents(event: String) async throws {
    let fixture = FolderTraceFixture(), coordinator = fixture.coordinator
    let old = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    let b = fixture.root.appendingPathComponent("B")
    let current = coordinator.begin(folder: b, rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .end(.replaced, 1), .begin(2, b)])
    #expect(await fixture.access.balance == [2, 0])
    try await fixture.scanner.deliver(["b2.png"], at: 1)
    let snapshot = coordinator.snapshot
    if event == "batch" { try await fixture.scanner.deliver(["a1.png"]) }
    await fixture.scanner.finish(failing: event == "error")
    try await old.value
    #expect(coordinator.snapshot == snapshot)
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .end(.replaced, 1), .begin(2, b), .firstBatch(1, 2)])
    await fixture.scanner.finish(1)
    try await current.value
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .end(.replaced, 1), .begin(2, b),
        .firstBatch(1, 2), .complete(1, 2), .end(.complete, 2)])
    #expect(coordinator.snapshot?.entries.map(\.url) == [b.appendingPathComponent("b2.png")])
    #expect(await fixture.access.balance == [2, 2])
}

@Test @MainActor func folderScanTraceEmptyAndAcquisitionFailure() async throws {
    let fixture = FolderTraceFixture()
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver([])
    await fixture.scanner.finish()
    try await task.value
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .complete(0, 1), .end(.complete, 1)])
    #expect(fixture.coordinator.snapshot?.entries == [])
    #expect(await fixture.access.balance == [1, 1])
    let failed = FolderTraceFixture(fails: true)
    let failure = failed.coordinator.begin(folder: failed.folder, rootID: failed.id)
    await #expect(throws: FolderScanTestError.expected) { try await failure.value }
    #expect(failed.trace.events == [.begin(1, failed.folder), .end(.failed, 1)])
    #expect(failed.coordinator.failure is FolderScanTestError)
    #expect(await failed.access.balance == [0, 0])
}

@Test @MainActor func folderScanTraceReturnedTaskCancellationEndsOnce() async throws {
    let fixture = FolderTraceFixture()
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    task.cancel()
    #expect(await fixture.access.balance == [1, 0])
    await fixture.scanner.finish()
    try await task.value
    #expect(fixture.trace.events == [.begin(1, fixture.folder), .end(.cancelled, 1)])
    #expect(fixture.coordinator.snapshot == nil)
    #expect(fixture.coordinator.failure == nil)
    #expect(await fixture.access.balance == [1, 1])
}

@Test func folderScanOutcomeLogValuesAreLiteral() {
    #expect(FolderScanOutcome.complete.rawValue == "complete")
    #expect(FolderScanOutcome.cancelled.rawValue == "cancelled")
    #expect(FolderScanOutcome.replaced.rawValue == "replaced")
    #expect(FolderScanOutcome.failed.rawValue == "failed")
}
