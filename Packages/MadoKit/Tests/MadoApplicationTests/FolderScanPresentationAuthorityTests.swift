import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor FolderAuthorityBarrier {
    private var ending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { ending = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if ending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { ending?.resume(); ending = nil }
}

@MainActor private final class FolderAuthorityHost: FolderScanHost {
    var opens: [URL] = []
    var remembered: [URL] = []
    var rememberAttempts = 0
    var beforeRememberCommit: (() async -> Void)?
    var commitAllowed: () -> Bool = { true }
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws {
        rememberAttempts += 1
        await beforeRememberCommit?()
        if commitAllowed() { remembered.append(folder) }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderAuthorityTracksAccessInputAndOriginIndependently() async {
    let accessIntent = AccessIntent(), inputIntent = AccessIntent(), originBarrier = FolderAuthorityBarrier()
    let access = accessIntent.current, input = inputIntent.current
    let origin = Task { await originBarrier.hold() }
    await originBarrier.waitForStart()
    let authority = FolderScanPresentationAuthority(access: access, input: input, originatingTask: origin)
    #expect(authority.isCurrent)
    let newerInput = inputIntent.begin()
    #expect(access.isCurrent && !origin.isCancelled && newerInput.isCurrent)
    #expect(!authority.isCurrent)
    let afterInput = FolderScanPresentationAuthority(access: access, input: newerInput, originatingTask: origin)
    #expect(afterInput.isCurrent)
    let newerAccess = accessIntent.begin()
    #expect(!afterInput.isCurrent)
    let afterAccess = FolderScanPresentationAuthority(access: newerAccess, input: newerInput, originatingTask: origin)
    #expect(afterAccess.isCurrent)
    origin.cancel()
    #expect(newerAccess.isCurrent && newerInput.isCurrent)
    #expect(!afterAccess.isCurrent)
    let withoutOrigin = FolderScanPresentationAuthority(access: newerAccess, input: newerInput, originatingTask: nil)
    #expect(withoutOrigin.isCurrent)
    await originBarrier.finish(); await origin.value
}

@Test(.timeLimit(.minutes(2)), arguments: ["first", "pending", "empty"])
@MainActor func folderAuthorityNewInputBlocksOldAutomaticEffects(effect: String) async throws {
    let fixture = FolderScanFixture(), host = FolderAuthorityHost()
    let accessIntent = AccessIntent(), inputIntent = AccessIntent(), originBarrier = FolderAuthorityBarrier()
    let access = accessIntent.current
    let origin = Task { await originBarrier.hold() }
    await originBarrier.waitForStart()
    let authority = FolderScanPresentationAuthority(access: access, input: inputIntent.current, originatingTask: origin)
    host.commitAllowed = { authority.isCurrent }; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: effect == "pending" ? fixture.folder.appendingPathComponent("img1.png") : nil,
        pending: effect == "pending" ? .next : nil, canPresent: { authority.isCurrent })
    await fixture.scanner.waitForStart()
    let newerInput = inputIntent.begin()
    #expect(access.isCurrent && !origin.isCancelled && newerInput.isCurrent)
    #expect(!authority.isCurrent)
    if effect != "empty" { try await fixture.scanner.deliver(["img1.png", "img2.png"]) }
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.isEmpty && host.remembered.isEmpty && host.rememberAttempts == 0 && !fixture.coordinator.isEmptyFolder)
    // Fix round 1: the authorized foreground policy is replaced, not silently completed.
    #expect(fixture.coordinator.snapshot?.isComplete == (effect == "pending" ? true : nil))
    #expect(await fixture.access.balance == [1, 1])
    if effect == "pending" {
        #expect(fixture.coordinator.move(.next))
        #expect(host.opens == [fixture.folder.appendingPathComponent("img2.png")])
        #expect(!authority.isCurrent && newerInput.isCurrent)
    }
    await originBarrier.finish(); await origin.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderAuthorityNewInputDuringRememberPreventsCommitAndOpen() async throws {
    let fixture = FolderScanFixture(), host = FolderAuthorityHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let accessIntent = AccessIntent(), inputIntent = AccessIntent()
    let originBarrier = FolderAuthorityBarrier(), rememberBarrier = FolderAuthorityBarrier()
    let access = accessIntent.current
    let origin = Task { await originBarrier.hold() }
    await originBarrier.waitForStart()
    let authority = FolderScanPresentationAuthority(access: access, input: inputIntent.current, originatingTask: origin)
    coordinator.host = host
    host.commitAllowed = { authority.isCurrent }
    host.beforeRememberCommit = { await rememberBarrier.hold() }
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, canPresent: { authority.isCurrent })
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"])
    await fixture.scanner.finish()
    await rememberBarrier.waitForStart()
    #expect(host.rememberAttempts == 1 && host.remembered.isEmpty && host.opens.isEmpty)
    let newerInput = inputIntent.begin()
    #expect(access.isCurrent && !origin.isCancelled && newerInput.isCurrent)
    #expect(!authority.isCurrent)
    await rememberBarrier.finish(); try await task.value
    #expect(host.remembered.isEmpty && host.opens.isEmpty)
    #expect(!coordinator.isEmptyFolder && coordinator.failure == nil)
    #expect(coordinator.snapshot == nil)
    #expect(coordinator.inputURL == nil && coordinator.currentItemID == nil && coordinator.currentURL == nil)
    #expect(coordinator.pendingDirection == nil && !coordinator.isReadingFolder)
    #expect(coordinator.automaticPresentationAllowed == nil)
    #expect(trace.events == ["begin-1", "first-1", "replaced-1"])
    coordinator.cancel()
    #expect(trace.events == ["begin-1", "first-1", "replaced-1"])
    #expect(await fixture.access.balance == [1, 1])
    await originBarrier.finish(); await origin.value
}
