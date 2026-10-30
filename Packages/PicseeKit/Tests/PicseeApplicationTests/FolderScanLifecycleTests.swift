import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

enum FolderScanTestError: Error { case expected }

actor FolderScanCountingLeases: AccessLeasing {
    let root: URL
    let fails: Bool
    let holdsAcquire: Bool
    var requests: [AccessRequest] = []
    var acquired: [AccessLease] = []
    var released: [AccessLease] = []
    private var acquisition: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    init(root: URL, fails: Bool = false, holdsAcquire: Bool = false) {
        self.root = root; self.fails = fails; self.holdsAcquire = holdsAcquire
    }
    func acquire(_ request: AccessRequest) async throws -> AccessLease {
        requests.append(request)
        if holdsAcquire {
            await withCheckedContinuation { continuation in
                acquisition = continuation
                requestWaiter?.resume(); requestWaiter = nil
            }
        }
        if fails { throw FolderScanTestError.expected }
        guard case .root(let id, _) = request else { throw FileAccessError.outsideRoot }
        let lease = AccessLease(url: root, rootID: id)
        acquired.append(lease)
        return lease
    }
    func release(_ lease: AccessLease) { released.append(lease) }
    var balance: [Int] { [acquired.count, released.count] }
    func waitForHeldAcquisition() async {
        if acquisition != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func resumeAcquisition() { acquisition?.resume(); acquisition = nil }
}

/// Deliberately ignores cancellation until finish, so lease lifetime and stale callbacks are observable.
actor FolderScanControlledScanner: FolderScanning {
    struct Call: Sendable {
        let folder: URL
        let root: ItemIdentityRoot
        let options: FolderScanOptions
    }
    private enum Event: Sendable {
        case batch([String], CheckedContinuation<Void, any Error>)
        case finish(Bool, (any Error & Sendable)?)
    }
    private var calls: [Call] = []
    private var events: [[Event]] = []
    private var receivers: [Int: CheckedContinuation<Event, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var startedCount: Int { calls.count }
    func scan(in folder: URL, root: ItemIdentityRoot,
              options: FolderScanOptions, emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let index = calls.count
        calls.append(Call(folder: folder, root: root, options: options)); events.append([])
        let ready = waiters.filter { calls.count > $0.0 }
        waiters.removeAll { calls.count > $0.0 }
        ready.forEach { $0.1.resume() }
        while true {
            switch await nextEvent(index) {
            case .batch(let names, let acknowledgement):
                let entries = names.map { FolderEntry(url: folder.appendingPathComponent($0), root: root) }
                do { try await emit(entries); acknowledgement.resume() }
                catch { acknowledgement.resume(throwing: error) }
            case .finish(let failing, let error):
                if failing { throw error ?? FolderScanTestError.expected }
                return
            }
        }
    }
    private func nextEvent(_ index: Int) async -> Event {
        if !events[index].isEmpty { return events[index].removeFirst() }
        return await withCheckedContinuation { receivers[index] = $0 }
    }
    private func send(_ event: Event, at index: Int) {
        if let receiver = receivers.removeValue(forKey: index) { receiver.resume(returning: event) }
        else { events[index].append(event) }
    }
    func waitForStart(_ index: Int = 0) async {
        if calls.count > index { return }
        await withCheckedContinuation { waiters.append((index, $0)) }
    }
    func root(at index: Int) -> ItemIdentityRoot { calls[index].root }
    func folder(at index: Int) -> URL { calls[index].folder }
    func options(at index: Int) -> FolderScanOptions { calls[index].options }
    func deliver(_ names: [String], at index: Int = 0) async throws {
        try await withCheckedThrowingContinuation { send(.batch(names, $0), at: index) }
    }
    func finish(_ index: Int = 0, failing: Bool = false, error: (any Error & Sendable)? = nil) {
        send(.finish(failing, error), at: index)
    }
}

@MainActor struct FolderScanFixture {
    let root: URL
    let id = AccessRootID()
    let scanner: FolderScanControlledScanner
    let access: FolderScanCountingLeases
    let coordinator: FolderScanCoordinator
    init(fails: Bool = false, holdsAcquire: Bool = false) {
        let root = URL(fileURLWithPath: "/folder-scan-tests")
        let scanner = FolderScanControlledScanner()
        let access = FolderScanCountingLeases(root: root, fails: fails, holdsAcquire: holdsAcquire)
        self.root = root; self.scanner = scanner; self.access = access
        coordinator = FolderScanCoordinator(access: access, scanner: scanner)
    }
    var folder: URL { root.appendingPathComponent("A") }
}

@Test @MainActor func folderScanBeginsReadingBeforeAcquisition() async throws {
    let fixture = FolderScanFixture()
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    #expect(fixture.coordinator.isReadingFolder)
    #expect(fixture.coordinator.snapshot == nil)
    #expect(fixture.coordinator.generation == 1)
    fixture.coordinator.cancel()
    try await task.value
    #expect(!fixture.coordinator.isReadingFolder)
    #expect(fixture.coordinator.snapshot == nil)
}

@Test(arguments: ["complete", "cancel", "failed", "replaced", "end"])
@MainActor func folderScanLeaseEndings(ending: String) async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    #expect(await fixture.access.requests == [.root(fixture.id, file: fixture.folder)])
    #expect(await fixture.access.balance == [1, 0])
    #expect(await fixture.scanner.root(at: 0).url == fixture.root)
    try await fixture.scanner.deliver(["img10.png", "img2.png"])
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img2.png", "img10.png"])
    var replacement: Task<Void, any Error>?
    if ending == "cancel" { coordinator.cancel() }
    if ending == "end" { coordinator.end() }
    if ending == "replaced" {
        replacement = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(1)
    }
    await fixture.scanner.finish(failing: ending == "failed")
    if ending == "failed" {
        await #expect(throws: FolderScanTestError.expected) { try await task.value }
        #expect(coordinator.failure is FolderScanTestError)
    } else { try await task.value }
    if let replacement {
        await fixture.scanner.finish(1)
        try await replacement.value
    }
    let acquired = await fixture.access.acquired, released = await fixture.access.released
    #expect(acquired == released)
    #expect(acquired.count == (ending == "replaced" ? 2 : 1))
    #expect(!coordinator.isReadingFolder)
    if ending == "complete" || ending == "replaced" { #expect(coordinator.snapshot?.isComplete == true) }
    if ending == "cancel" || ending == "end" { #expect(coordinator.snapshot == nil) }
}

@Test(arguments: ["batch", "completion", "error"])
@MainActor func folderScanOldBatchCompletionErrorCannotBackflow(event: String) async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator
    let old = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    let b = fixture.root.appendingPathComponent("B")
    let current = coordinator.begin(folder: b, rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["b2.png"], at: 1)
    let snapshot = coordinator.snapshot, reading = coordinator.isReadingFolder
    #expect(snapshot?.version.generation == 2)
    #expect(snapshot?.isComplete == false)
    if event == "batch" { try await fixture.scanner.deliver(["a1.png"]) }
    await fixture.scanner.finish(failing: event == "error")
    try await old.value
    #expect(coordinator.snapshot == snapshot)
    #expect(coordinator.isReadingFolder == reading)
    #expect(coordinator.failure == nil)
    #expect(coordinator.snapshot?.entries.map(\.url) == [b.appendingPathComponent("b2.png")])
    await fixture.scanner.finish(1)
    try await current.value
    #expect(coordinator.snapshot?.isComplete == true)
    #expect(await fixture.access.balance == [2, 2])
}

@Test(arguments: ["cancel", "end", "replaced"])
@MainActor func folderScanCancelRetainsLeaseUntilScannerExits(ending: String) async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    let firstLease = try #require(await fixture.access.acquired.first)
    var replacement: Task<Void, any Error>?
    if ending == "cancel" { coordinator.cancel() }
    if ending == "end" { coordinator.end() }
    if ending == "replaced" {
        replacement = coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
        await fixture.scanner.waitForStart(1)
    }
    #expect(await fixture.access.released.isEmpty)
    let before = coordinator.snapshot
    try await fixture.scanner.deliver(["late.png"])
    #expect(coordinator.snapshot == before)
    await fixture.scanner.finish()
    try await task.value
    #expect(await fixture.access.released == [firstLease])
    if let replacement {
        await fixture.scanner.finish(1)
        try await replacement.value
    }
    coordinator.end(); coordinator.end()
    let acquired = await fixture.access.acquired, released = await fixture.access.released
    #expect(acquired == released)
    #expect(coordinator.snapshot == nil)
    #expect(!coordinator.isReadingFolder)
}

@Test(arguments: [false, true])
@MainActor func folderScanCancelThenLateCompletionAndError(failing: Bool) async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img2.png"])
    coordinator.cancel()
    try await fixture.scanner.deliver(["late.png"])
    await fixture.scanner.finish(failing: failing)
    try await task.value
    coordinator.end()
    #expect(coordinator.snapshot == nil)
    #expect(coordinator.failure == nil)
    #expect(!coordinator.isReadingFolder)
    #expect(await fixture.access.balance == [1, 1])
}

@Test @MainActor func folderScanCancelDuringAcquisitionNeverEnumerates() async throws {
    let fixture = FolderScanFixture(holdsAcquire: true), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.access.waitForHeldAcquisition()
    coordinator.cancel()
    await fixture.access.resumeAcquisition()
    try await task.value
    #expect(await fixture.scanner.startedCount == 0)
    #expect(await fixture.access.balance == [1, 1])
    #expect(coordinator.snapshot == nil)
    #expect(!coordinator.isReadingFolder)
}

@Test @MainActor func folderScanAcquireErrorsEndReadingWithoutLease() async {
    let fixture = FolderScanFixture(fails: true), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await #expect(throws: FolderScanTestError.expected) { try await task.value }
    #expect(coordinator.failure is FolderScanTestError)
    #expect(!coordinator.isReadingFolder)
    #expect(coordinator.snapshot == nil)
    #expect(await fixture.access.balance == [0, 0])
    #expect(await fixture.scanner.startedCount == 0)
}

@Test @MainActor func folderScanInputRemainsBackgroundAndCompletionIsImmutable() async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator
    let input = fixture.folder.appendingPathComponent("img2.png")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    #expect(!coordinator.isReadingFolder)
    #expect(coordinator.inputURL == input)
    await fixture.scanner.waitForStart()
    let initial = coordinator.snapshot
    try await fixture.scanner.deliver(["img2.png"])
    #expect(initial?.entries == [])
    #expect(initial?.isComplete == false)
    await fixture.scanner.finish()
    try await task.value
    let complete = coordinator.snapshot
    #expect(coordinator.snapshot == complete)
    #expect(complete?.entries.map(\.url) == [input])
    #expect(complete?.isComplete == true)
    #expect(!coordinator.isReadingFolder)
}

@Test @MainActor func folderScanReturnedTaskCancellationEndsWithoutFailure() async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    task.cancel()
    #expect(await fixture.access.balance == [1, 0])
    await fixture.scanner.finish()
    try await task.value
    #expect(coordinator.snapshot == nil)
    #expect(coordinator.inputURL == nil)
    #expect(coordinator.failure == nil)
    #expect(!coordinator.isReadingFolder)
    #expect(await fixture.access.balance == [1, 1])
}
