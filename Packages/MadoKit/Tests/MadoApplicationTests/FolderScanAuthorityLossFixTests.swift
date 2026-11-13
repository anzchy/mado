import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2)), arguments: ["empty-batch", "showing-batch", "empty-complete", "showing-complete", "empty-error", "showing-error"])
@MainActor func folderFixAuthorityLossRestoresPriorPresentation(event: String) async throws {
    let fixture = FolderScanFixture(), host = FolderFixEffectsHost(), trace = FolderFixTrace()
    let coordinator = FolderScanCoordinator(access: fixture.access, scanner: fixture.scanner, trace: trace)
    let session = ViewerSession(), imageHost = LoadHost(), pipeline = LoadPipeline(), leases = LoadLeases()
    coordinator.host = host; session.folderScan = coordinator; session.imageLoader.host = imageHost
    if event.hasPrefix("showing") {
        let prior = URL(fileURLWithPath: "/prior.png")
        session.openImage(prior, maximumPixelSize: 512) {
            try await AccessImageSource.open(.fileGrant(prior), access: leases, pipeline: pipeline)
        }
        await session.imageLoader.loadTask?.value
    }
    let before = session.imageStatus, key = session.imageLoader.presented?.key
    let accessIntent = AccessIntent(), inputIntent = AccessIntent()
    let authority = FolderScanPresentationAuthority(access: accessIntent.current, input: inputIntent.current, originatingTask: nil)
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, canPresent: { authority.isCurrent })
    await fixture.scanner.waitForStart()
    #expect(session.imageStatus == .readingFolder)
    _ = inputIntent.begin()
    if event.hasSuffix("batch") {
        try await fixture.scanner.deliver(["img2.png", "img10.png"])
        #expect(session.imageStatus == before && coordinator.snapshot == nil)
        #expect(await fixture.access.balance == [1, 0])
        try await fixture.scanner.deliver(["late.png"])
    }
    await fixture.scanner.finish(failing: event.hasSuffix("error")); try await task.value
    #expect(session.imageStatus == before && session.imageLoader.presented?.key == key)
    #expect(coordinator.snapshot == nil && !coordinator.isReadingFolder && coordinator.failure == nil)
    #expect(host.opens.isEmpty && host.remembered.isEmpty && !coordinator.isEmptyFolder)
    #expect(trace.events == ["begin-1", "replaced-1"])
    #expect(await fixture.access.balance == [1, 1])
    session.closeImage()
}
