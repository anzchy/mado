import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2)), arguments: ["scanning", "completed", "pending-complete", "pending-error"])
@MainActor func folderFixImageCancelRetiresContext(ending: String) async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession()
    host.hasImage = false; session.host = host
    fixture.coordinator.host = host; session.folderScan = fixture.coordinator
    let pipeline = GenerationPipeline(), access = LoadLeases(), imageHost = LoadHost()
    session.imageLoader.host = imageHost
    let file = fixture.folder.appendingPathComponent("img2.png")
    session.openImage(file, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    let loading = session.imageLoader.loadTask
    await pipeline.entered("img2.png")
    let pending = ending.hasPrefix("pending")
    let scan = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: file,
        pending: pending ? .next : nil)
    await fixture.scanner.waitForStart()
    if !pending { try await fixture.scanner.deliver(["img1.png", "img2.png", "img10.png"]) }
    if ending == "completed" { await fixture.scanner.finish(); try await scan.value }
    #expect(session.imageStatus == .loading("img2.png"))
    session.cancelImageOpening(); session.cancelImageOpening()
    #expect(session.imageStatus == .empty)
    #expect(fixture.coordinator.snapshot == nil && fixture.coordinator.currentItemID == nil)
    #expect(fixture.coordinator.pendingDirection == nil)
    #expect(!session.isEnabled(.next) && !session.isEnabled(.previous))
    #expect(!CommandRouter().route(.next, from: .key, to: session))
    if ending != "completed" {
        #expect(await fixture.access.balance == [1, 0])
        try await fixture.scanner.deliver(["img2.png", "img10.png"])
        #expect(fixture.coordinator.snapshot == nil)
        await fixture.scanner.finish(failing: ending == "pending-error"); try await scan.value
    }
    await pipeline.release("img2.png"); await loading?.value
    #expect(host.opens.isEmpty && host.navigation.isEmpty && imageHost.names.isEmpty)
    #expect(session.imageStatus == .empty && fixture.coordinator.failure == nil)
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderFixFailedImageStillOffersNext() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession()
    host.hasImage = false; session.host = host; session.folderScan = fixture.coordinator
    fixture.coordinator.host = host
    let file = fixture.folder.appendingPathComponent("img2.png")
    session.openImage(file, maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
    await session.imageLoader.loadTask?.value
    let scan = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: file)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img2.png", "img10.png"])
    await fixture.scanner.finish(); try await scan.value
    #expect(session.imageStatus == .failed(.corruptImage, "img2.png"))
    #expect(session.isEnabled(.next))
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.opens.map(\.0.lastPathComponent) == ["img10.png"])
    session.cancelImageOpening()
}
