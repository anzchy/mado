import Foundation
import Testing
import MadoCore
@testable import MadoApplication
import MadoInfrastructure

private actor LimitLeases: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease {
        AccessLease(url: URL(fileURLWithPath: "/unused"), rootID: nil)
    }
    func release(_ lease: AccessLease) { }
}
@MainActor private final class LimitHost: ViewerImageHost {
    var images = 0, failures = 0
    func beginImageOpening() { }
    func installImage(_ image: DecodedImage, fileURL: URL) { images += 1 }
    func imageLoadFailed(_ error: any Error) { failures += 1 }
}
@MainActor @Test func loadResourceLimitKeepsPreviewAndFailsOnlyWithoutPixels() async {
    let session = ViewerSession(), host = LimitHost(), access = LimitLeases()
    session.imageLoader.host = host
    let file = fixture("pan-grid-4096x3072.png")
    let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: 1_000_000))
    session.openImage(file, maximumPixelSize: 1000) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .detailLimited)
    #expect(host.images == 1)
    #expect(host.failures == 0)
    #expect(session.imageLoader.presented?.name == "pan-grid-4096x3072.png")
    #expect((session.imageLoader.failure as? ImageLoadError)?.kind == .resourceLimit)
    #expect((session.imageLoader.failure as? ImageLoadError)?.itemID == session.imageLoader.presented?.key.itemID)
    #expect((session.imageLoader.failure as? ImageLoadError)?.revision == session.imageLoader.presented?.key.revision)
    let tiny = ImageIOPipeline(configuration: DecodeConfiguration(budget: 1))
    session.openImage(file, maximumPixelSize: 1000) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: tiny)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageLoader.phase == .failed)
    #expect((session.imageLoader.failure as? ImageLoadError)?.kind == .resourceLimit)
    #expect(session.imageLoader.presented == nil)
    #expect(host.failures == 1)
}
