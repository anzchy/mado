import Foundation
import os
import Testing
import PicseeCore
@testable import PicseeApplication

private final class HeldFolderMetadataReader: FolderMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = TestGate()
    private var names: [String] = []
    func read(_ url: URL) throws -> FolderImageMetadata {
        lock.lock(); names.append(url.lastPathComponent); lock.unlock()
        gate.wait()
        return .init(captureDate: Date(timeIntervalSince1970: url.lastPathComponent == "b.jpg" ? 1 : 2))
    }
    func release() { gate.signal() }
    func open() { gate.open() }
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

private final class ImmediateFolderMetadataReader: FolderMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func read(_ url: URL) throws -> FolderImageMetadata {
        lock.lock(); names.append(url.lastPathComponent); lock.unlock()
        return .init(captureDate: Date(timeIntervalSince1970: url.lastPathComponent == "b.jpg" ? 1 : 2))
    }
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

private struct FailingFolderMetadataReader: FolderMetadataReading {
    func read(_ url: URL) throws -> FolderImageMetadata { throw FolderScanTestError.expected }
}

private struct PartialFolderMetadataReader: FolderMetadataReading {
    func read(_ url: URL) throws -> FolderImageMetadata { .init(pixelWidth: 4) }
}

@MainActor private final class CancelledRememberHost: FolderScanHost {
    func openFolderImage(_ url: URL, rootID: AccessRootID) {}
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { throw CancellationError() }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108MetadataSortPendingInvalidatesStaleRepliesAndKeepsBaseList() async throws {
    let fixture = FolderScanFixture(), reader = HeldFolderMetadataReader()
    defer { reader.open() }
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.jpg"])
    await fixture.scanner.finish(); try await task.value
    #expect(reader.requested.isEmpty)
    coordinator.setConditions(.init(sort: .captureDate))
    #expect(coordinator.isMetadataSortPending)
    #expect(coordinator.snapshot?.entries.count == 2)
    try await waitUntil { !reader.requested.isEmpty }
    #expect(reader.requested.count == 1)
    coordinator.setConditions(.init(sort: .name))
    reader.release()
    #expect(!coordinator.isMetadataSortPending)
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["a.jpg", "b.jpg"])
    #expect(coordinator.currentItemID == coordinator.snapshot?.entries.first?.itemID)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108LateMetadataBatchExtendsPendingAndPreservesCurrentIdentity() async throws {
    let fixture = FolderScanFixture(), reader = ImmediateFolderMetadataReader()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    coordinator.setConditions(.init(sort: .captureDate))
    try await fixture.scanner.deliver(["a.jpg"])
    #expect(coordinator.isMetadataSortPending)
    let originalID = coordinator.currentItemID
    try await fixture.scanner.deliver(["b.jpg"])
    await fixture.scanner.finish(); try await task.value
    try await waitUntil { !coordinator.isMetadataSortPending }
    #expect(!coordinator.isMetadataSortPending)
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["b.jpg", "a.jpg"])
    #expect(coordinator.currentItemID == originalID)
    #expect(Set(reader.requested) == ["a.jpg", "b.jpg"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108FolderReplacementRejectsHeldMetadataAndReleasesLeases() async throws {
    let fixture = FolderScanFixture(), reader = HeldFolderMetadataReader()
    defer { reader.open() }
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let old = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["old.jpg"])
    await fixture.scanner.finish(); try await old.value
    coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { !reader.requested.isEmpty }
    let replacement = fixture.root.appendingPathComponent("B")
    let new = coordinator.begin(folder: replacement, rootID: fixture.id)
    reader.release()
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["new.jpg"], at: 1)
    await fixture.scanner.finish(1); try await new.value
    #expect(coordinator.snapshot?.version.folder == replacement)
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["new.jpg"])
    #expect(coordinator.conditions.sort == .captureDate)
    try await waitUntil { reader.requested.count >= 2 }
    #expect(reader.requested.contains("new.jpg"))
    reader.release()
    try await waitUntil { let balance = await fixture.access.balance; return balance[0] == balance[1] }
    let balance = await fixture.access.balance
    #expect(balance[0] == balance[1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108MetadataReadFailureSettlesAsExplicitUnknown() async throws {
    let fixture = FolderScanFixture()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner,
        metadataReader: FailingFolderMetadataReader())
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await task.value
    let itemID = try #require(coordinator.snapshot?.entries.first?.itemID)
    coordinator.setConditions(.init(sort: .pixelDimensions))
    try await waitUntil { coordinator.metadataSortState != .pending }
    #expect(coordinator.metadataSortState == .incomplete)
    #expect(coordinator.metadataUnknownItemIDs == [itemID])
    #expect(coordinator.snapshot?.entries.first?.itemID == itemID)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108MissingChosenFieldRemainsIncomplete() async throws {
    let fixture = FolderScanFixture()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner,
        metadataReader: PartialFolderMetadataReader())
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await task.value
    for sort in [FolderSortKey.captureDate, .pixelDimensions] {
        coordinator.setConditions(.init(sort: sort))
        try await waitUntil { coordinator.metadataSortState != .pending }
        #expect(coordinator.metadataSortState == .incomplete)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108PartialScanFailureKeepsReadMetadata() async throws {
    let fixture = FolderScanFixture(), reader = ImmediateFolderMetadataReader()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    coordinator.setConditions(.init(sort: .captureDate))
    try await fixture.scanner.deliver(["a.jpg", "b.jpg"])
    try await waitUntil { reader.requested.count >= 2 }
    try await waitUntil { coordinator.metadataProjectionCount != 0 }
    await fixture.scanner.finish(failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await task.value }
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["b.jpg", "a.jpg"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108StaleReplyCannotPopulateNewSortAfterDrain() async throws {
    let fixture = FolderScanFixture(), reader = HeldFolderMetadataReader()
    defer { reader.open() }
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await task.value
    coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { !reader.requested.isEmpty }
    coordinator.setConditions(.init(sort: .name))
    coordinator.setConditions(.init(sort: .captureDate))
    reader.release()
    try await waitUntil { reader.requested.count >= 2 }
    #expect(coordinator.metadataSortState == .pending)
    reader.release()
    try await waitUntil { coordinator.metadataSortState != .pending }
    #expect(coordinator.metadataSortState == .complete)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108CancelledScanDropsSourceAndMetadataWork() async throws {
    let fixture = FolderScanFixture(), reader = HeldFolderMetadataReader(), host = CancelledRememberHost()
    defer { reader.open() }
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    coordinator.setConditions(.init(sort: .captureDate))
    try await fixture.scanner.deliver(["a.jpg"])
    try await waitUntil { !reader.requested.isEmpty }
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil)
    #expect(coordinator.metadataSortState == .idle)
    reader.release()
    try await waitUntil { let balance = await fixture.access.balance; return balance[0] == balance[1] }
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil)
    let balance = await fixture.access.balance
    #expect(balance[0] == balance[1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108RemovedEntriesDoNotStrandRemainingMetadataQueue() async throws {
    let fixture = FolderScanFixture(), reader = HeldFolderMetadataReader()
    defer { reader.open() }
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.jpg", "c.jpg"])
    await fixture.scanner.finish(); try await task.value
    coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { !reader.requested.isEmpty }
    let source = try #require(coordinator.sourceSnapshot)
    coordinator.replaceSourceSnapshot(FolderSnapshot(version: source.version,
        entries: source.entries.filter { $0.url.lastPathComponent == "c.jpg" }, isComplete: true))
    reader.release()
    try await waitUntil { reader.requested.count >= 2 }
    #expect(reader.requested == ["a.jpg", "c.jpg"])
    reader.release()
    try await waitUntil { coordinator.metadataSortState != .pending }
    #expect(coordinator.metadataSortState == .complete)
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["c.jpg"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108RapidSortChangesKeepAtMostOneReadInFlight() async throws {
    let fixture = FolderScanFixture(), reader = HeldFolderMetadataReader()
    defer { reader.open() }
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await task.value
    coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { !reader.requested.isEmpty }
    coordinator.setConditions(.init(sort: .pixelDimensions))
    coordinator.setConditions(.init(sort: .captureDate))
    try await Task.sleep(for: .milliseconds(20))
    #expect(reader.requested.count == 1)
    reader.release()
    try await waitUntil { reader.requested.count >= 2 }
    #expect(reader.requested.count == 2)
    reader.release()
    try await waitUntil { !coordinator.isMetadataSortPending }
    #expect(!coordinator.isMetadataSortPending)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue108ManyHeadersPublishBoundedSortBatches() async throws {
    let fixture = FolderScanFixture(), reader = ImmediateFolderMetadataReader()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    let names = (0..<1024).map { "img\($0).jpg" }
    try await fixture.scanner.deliver(names)
    await fixture.scanner.finish(); try await task.value
    coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { !coordinator.isMetadataSortPending }
    #expect(!coordinator.isMetadataSortPending)
    #expect(reader.requested.count == 1024)
    #expect(coordinator.snapshot?.entries.count == 1024)
    #expect(coordinator.metadataProjectionCount <= 17)
}

// This stress case starts up to 32 coordinators and deliberately holds synchronous readers;
// allow loaded CI hosts to schedule the setup while retaining the 400 ms executor probe below.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue108HeldMetadataHeadersLeaveCooperativeExecutorResponsive() async throws {
    let reader = HeldFolderMetadataReader()
    defer { reader.open() }
    let workerCount = ProcessInfo.processInfo.activeProcessorCount
    let count = max(4, min(workerCount * 2, 32))
    var coordinators: [FolderScanCoordinator] = []
    for _ in 0..<count {
        let fixture = FolderScanFixture()
        let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, metadataReader: reader)
        let scan = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["a.jpg"])
        await fixture.scanner.finish()
        try await scan.value
        coordinators.append(coordinator)
    }
    for coordinator in coordinators { coordinator.setConditions(.init(sort: .captureDate)) }
    // The probe itself must not need a cooperative worker to release blocked reads. It waits for them with no
    // wall-clock deadline (#277); cancellation by the time limit stops it.
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let (started, elapsed) = await withTaskCancellationHandler { await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            while reader.requested.count < workerCount && !cancelled.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let started = reader.requested.count
            let start = ContinuousClock.now
            Task.detached { continuation.resume(returning: (started, ContinuousClock.now - start)) }
            Thread.sleep(forTimeInterval: 0.8)
            for _ in 0..<count { reader.release() }
        }
    } } onCancel: { cancelled.withLock { $0 = true } }
    #expect(started >= workerCount)
    #expect(elapsed < .milliseconds(400))
    try await Task.sleep(for: .milliseconds(900))
    for coordinator in coordinators { coordinator.end() }
}
