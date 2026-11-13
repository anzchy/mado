import Foundation
import Testing
import MadoCore
@testable import MadoApplication

actor FolderFixBarrier {
    private var exit: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { exit = $0; arrival?.resume(); arrival = nil } }
    func entered() async {
        if exit == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func finish() { exit?.resume(); exit = nil }
}
@MainActor final class FolderFixEffectsHost: FolderScanHost {
    var opens: [URL] = []
    var remembered: [URL] = []
    var onRemember: (() async -> Void)?
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async {
        remembered.append(folder); await onRemember?()
    }
}
private struct FolderFixReleaseLeases: AccessLeasing {
    let base: FolderScanCountingLeases
    let releasing: FolderFixBarrier
    func acquire(_ request: AccessRequest) async throws -> AccessLease { try await base.acquire(request) }
    func release(_ lease: AccessLease) async { await releasing.hold(); await base.release(lease) }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func folderFixTaskCancelRejectsLateEffects(input: Bool) async throws {
    let fixture = FolderScanFixture(), trace = FolderFixTrace(), host = FolderFixEffectsHost()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: input ? fixture.folder.appendingPathComponent("img2.png") : nil, pending: input ? .next : nil)
    await fixture.scanner.waitForStart()
    let before = coordinator.snapshot
    task.cancel()
    try await fixture.scanner.deliver(["img2.png", "img10.png"])
    #expect(coordinator.snapshot == before)
    #expect(host.opens.isEmpty && host.remembered.isEmpty && !coordinator.isEmptyFolder)
    #expect(trace.events == ["begin-1"])
    #expect(await fixture.access.balance == [1, 0])
    await fixture.scanner.finish(failing: input); try await task.value
    #expect(coordinator.snapshot == nil && coordinator.failure == nil && !coordinator.isReadingFolder)
    #expect(trace.events == ["begin-1", "cancelled-1"])
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderFixTaskCancelDuringAcquireNeverPublishesReady() async throws {
    let fixture = FolderScanFixture(holdsAcquire: true), releasing = FolderFixBarrier(), host = FolderFixEffectsHost()
    let coordinator = FolderScanCoordinator(access: FolderFixReleaseLeases(base: fixture.access, releasing: releasing), scanner: fixture.scanner)
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.access.waitForHeldAcquisition()
    task.cancel(); await fixture.access.resumeAcquisition()
    // Release is held before coordinator catch cleanup: observe transient ready publication too.
    await releasing.entered()
    #expect(coordinator.snapshot == nil && coordinator.currentItemID == nil)
    #expect(await fixture.scanner.startedCount == 0)
    #expect(host.opens.isEmpty && host.remembered.isEmpty)
    #expect(await fixture.access.balance == [1, 0])
    await releasing.finish(); try await task.value
    #expect(coordinator.snapshot == nil && !coordinator.isReadingFolder && coordinator.failure == nil)
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderFixTaskCancelDuringRememberCannotOpenOrPublishAgain() async throws {
    let fixture = FolderScanFixture(), host = FolderFixEffectsHost(), barrier = FolderFixBarrier()
    fixture.coordinator.host = host; host.onRemember = { await barrier.hold() }
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img2.png"])
    await fixture.scanner.finish()
    await barrier.entered(); task.cancel(); await barrier.finish(); try await task.value
    #expect(host.opens.isEmpty && host.remembered == [fixture.folder])
    #expect(fixture.coordinator.snapshot == nil && fixture.coordinator.failure == nil)
    #expect(await fixture.access.balance == [1, 1])
}
