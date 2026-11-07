import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor RenewalLeases: AccessLeasing {
    var attempts = 0
    var released = 0
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        attempts += 1
        if attempts == 4 { throw FileAccessError.startFailed }
        return AccessLease(url: URL(fileURLWithPath: "/renew.png"), rootID: nil)
    }
    func release(_ lease: AccessLease) { released += 1 }
}
private actor LimitedDetailPipeline: ImagePipeline {
    let key = RenderKey(itemID: .ephemeral(UUID()), revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: 512)
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key)
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        if !request.isPreview { throw ImageLoadError(.resourceLimit, itemID: key.itemID, revision: key.revision) }
        return loadImage(key)
    }
}
@MainActor @Test func loadResourceLimitReconnectionFailureClearsPixelsAndIdentity() async {
    let session = ViewerSession(), access = RenewalLeases(), pipeline = LimitedDetailPipeline(), host = LoadHost()
    session.imageLoader.host = host
    let file = URL(fileURLWithPath: "/renew.png")
    session.openImage(file, maximumPixelSize: 1000) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    #expect(host.images.count == 1 && host.failures == 1)
    #expect(session.imageLoader.phase == .failed)
    #expect(session.imageLoader.presented == nil)
    #expect(session.imageLoader.failure as? FileAccessError == .startFailed)
    #expect(await access.attempts == 4)
    #expect(await access.released == 3)
}
