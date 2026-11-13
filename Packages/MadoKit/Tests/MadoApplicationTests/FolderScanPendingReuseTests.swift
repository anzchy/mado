import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func folderFixReusePendingSessionArrows(finalPrevious: Bool) async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: nil)
    session.host = host; session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let input = fixture.folder.appendingPathComponent("img2.png")
    session.openImage(input, maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
    await session.imageLoader.loadTask?.value
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img0.png"])
    let generation = fixture.coordinator.generation
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(CommandRouter().route(.previous, from: .key, to: session))
    if !finalPrevious { #expect(CommandRouter().route(.next, from: .key, to: session)) }
    #expect(host.navigation.isEmpty && host.opens.isEmpty)
    #expect(fixture.coordinator.generation == generation)
    #expect(await fixture.scanner.startedCount == 1)
    #expect(await fixture.access.balance == [1, 0])
    try await fixture.scanner.deliver(["img1.png", "img2.png", "img10.png"])
    let expected = finalPrevious ? "img1.png" : "img10.png"
    #expect(host.opens.map(\.0.lastPathComponent) == [expected])
    #expect(fixture.coordinator.currentItemID == .rootRelative(rootID: fixture.id, relativePath: "A/\(expected)"))
    #expect(fixture.coordinator.pendingDirection == nil)
    try await fixture.scanner.deliver(["img20.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.map(\.0.lastPathComponent) == [expected])
    #expect(await fixture.access.balance == [1, 1])
    session.closeImage()
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderFixReuseMatchesOnlyLiveRequest() async throws {
    let fixture = FolderScanFixture(holdsAcquire: true), coordinator = fixture.coordinator
    let input = fixture.folder.appendingPathComponent("img2.png")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.access.waitForHeldAcquisition()
    #expect(coordinator.queueNavigation(.next, folder: fixture.folder, input: input, rootID: fixture.id))
    #expect(!coordinator.queueNavigation(.previous, folder: fixture.root, input: input, rootID: fixture.id))
    #expect(!coordinator.queueNavigation(.previous, folder: fixture.folder, input: input, rootID: AccessRootID()))
    #expect(!coordinator.queueNavigation(.previous, folder: fixture.folder, input: fixture.folder.appendingPathComponent("other.png")))
    #expect(coordinator.pendingDirection == .next && coordinator.snapshot == nil)
    await fixture.access.resumeAcquisition(); await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img2.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(!coordinator.queueNavigation(.next, folder: fixture.folder, input: input))
    let snapshot = coordinator.snapshot
    coordinator.cancel()
    #expect(!coordinator.queueNavigation(.next, folder: fixture.folder, input: input))
    #expect(snapshot?.isComplete == true && coordinator.snapshot == nil)
}
