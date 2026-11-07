import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor AccessRenewalPipeline: ImagePipeline {
    let revisionChange: Bool
    let key = RenderKey(itemID: .ephemeral(UUID()), revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: 512)
    var changed = false
    init(revisionChange: Bool) { self.revisionChange = revisionChange }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key)
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        if revisionChange && !changed { changed = true; throw ImageLoadError(.sourceChanged) }
        if !revisionChange && !request.isPreview { throw ImageLoadError(.resourceLimit) }
        return loadImage(key)
    }
}
@MainActor private final class AccessRenewalProbe {
    let intent = AccessIntent()
    var openings = 0
}
@MainActor @Test(arguments: [false, true])
func loadAccessRenewalUsesCurrentIntentAfterUnrelatedBegin(revisionChange: Bool) async {
    let probe = AccessRenewalProbe(), session = ViewerSession(), host = LoadHost(), access = LoadLeases()
    let pipeline = AccessRenewalPipeline(revisionChange: revisionChange)
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/access-renewal.png")
    _ = probe.intent.begin()
    let opener = ViewerImageLoader.accessOpener(intent: probe.intent) { operation in
        probe.openings += 1
        try operation.check()
        let source = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
        if probe.openings == 1 { _ = probe.intent.begin() } // e.g. an empty Open Folder result
        return source
    }
    session.openImage(file, maximumPixelSize: 1000, opener: opener)
    let generation = session.imageLoader.generation
    await session.imageLoader.loadTask?.value
    #expect(probe.openings == 2)
    #expect(session.imageLoader.generation == generation)
    #expect(session.imageLoader.phase == (revisionChange ? .settled : .detailLimited))
    #expect(session.imageLoader.presented?.name == "access-renewal.png")
    #expect(host.failures == 0)
    #expect(await access.acquired.count == (revisionChange ? 5 : 4))
    #expect(await access.released.count == (revisionChange ? 4 : 3))
}
