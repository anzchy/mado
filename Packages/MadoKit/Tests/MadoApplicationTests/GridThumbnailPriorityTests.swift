import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor GridThumbnailAccess: AccessLeasing {
    let root: ItemIdentityRoot
    private(set) var active = 0
    init(root: ItemIdentityRoot) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease {
        active += 1
        return AccessLease(url: root.url, rootID: root.id)
    }
    func release(_ lease: AccessLease) { active -= 1 }
}

private actor GridThumbnailPipeline: ImagePipeline {
    let root: ItemIdentityRoot
    init(root: ItemIdentityRoot) { self.root = root }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) -> ImageDecodeRequest {
        let key = RenderKey(itemID: .rootRelative(rootID: root.id, relativePath: fileURL.lastPathComponent),
            revision: FileRevision(byteCount: 7, modificationDate: nil), maximumPixelSize: maximumPixelSize)
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key)
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: request.renderKey?.revision, itemID: request.renderKey?.itemID)
    }
}

@Test func gridThumbnailPriorityTravelsThroughAuthorizedLeaseAndCloses() async throws {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/tmp/grid-priority"))
    let access = GridThumbnailAccess(root: root)
    let source = try await AccessImageSource.open(.root(root.id, file: root.url.appendingPathComponent("a.png")),
        access: access, pipeline: GridThumbnailPipeline(root: root))
    let (visible, image) = try await source.image(maximumPixelSize: 424, priority: .visible)
    #expect(visible.priority == .visible)
    #expect(visible.maximumPixelSize == 424)
    #expect(image.itemID == visible.renderKey?.itemID)
    let (prefetch, _) = try await source.image(maximumPixelSize: 212, priority: .prefetch)
    #expect(prefetch.priority == .prefetch)
    await source.close()
    #expect(await access.active == 0)
}
