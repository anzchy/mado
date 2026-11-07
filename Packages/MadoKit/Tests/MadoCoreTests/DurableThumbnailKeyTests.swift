import Foundation
import Testing
import MadoCore

@Test func durableThumbnailKeyUsesContentAndEveryRenderField() throws {
    let root = AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
    let item = ItemID.rootRelative(rootID: root, relativePath: "photo.png")
    let revision = FileRevision(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 100), resourceIdentifier: "session-only")
    let digest = String(repeating: "a", count: 64)
    func key(_ digest: String = digest, edge: Int = 128, preview: Bool = false,
             frame: Int = 0, policy: RenderPolicy = .orientedSDR,
             decoder: Int = 1, purpose: RenderPurpose = .thumbnail,
             encoder: Int = 1) throws -> DurableThumbnailKey {
        let render = RenderKey(itemID: item, revision: revision, maximumPixelSize: edge,
                               isPreview: preview, frameIndex: frame, policy: policy,
                               decoderVersion: decoder, purpose: purpose)
        return try #require(DurableThumbnailKey(renderKey: render, sourceSHA256: digest, encoderVersion: encoder))
    }
    let original = try key()
    #expect(original.encoding.hasPrefix("rkt1|"))
    #expect(original.filename.count == 64)
    #expect(original.filename == "f46eba67d4619780f51f97c586a6b08f3d521f6157387fd172fbd8bdd283d79c")
    #expect(!original.encoding.contains("session-only"))
    #expect(try key() == original)
    let restartedRevision = FileRevision(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 101),
                                         resourceIdentifier: "another-session")
    let restartedRender = RenderKey(itemID: item, revision: restartedRevision, maximumPixelSize: 128,
                                    purpose: .thumbnail)
    #expect(DurableThumbnailKey(renderKey: restartedRender, sourceSHA256: digest) == original)
    for changed in [try key(String(repeating: "b", count: 64)), try key(edge: 256), try key(preview: true),
                    try key(frame: 1), try key(policy: .unorientedSDR), try key(decoder: 2),
                    try key(purpose: .viewer), try key(encoder: 2)] {
        #expect(changed.filename != original.filename)
    }
    let grant = RenderKey(itemID: .ephemeral(UUID()), revision: revision, maximumPixelSize: 128)
    #expect(DurableThumbnailKey(renderKey: grant, sourceSHA256: digest) == nil)
    #expect(DurableThumbnailKey(renderKey: RenderKey(itemID: item, revision: revision, maximumPixelSize: 128), sourceSHA256: "bad") == nil)
}
