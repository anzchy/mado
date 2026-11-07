import Foundation
import Testing
import MadoCore

@Test func installationRequiresIdentityRevisionGenerationAndBinding() {
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 100))
    let key = RenderKey(itemID: item, revision: revision, maximumPixelSize: 512)
    let token = PresentationToken(binding: UUID(), generation: UUID())
    #expect(token.accepts(key: key, expected: key, token: token))
    #expect(!token.accepts(key: key, expected: RenderKey(itemID: ItemID.ephemeral(UUID()), revision: revision, maximumPixelSize: 512), token: token))
    for changed in [FileRevision(byteCount: 43, modificationDate: revision.modificationDate), FileRevision(byteCount: 42, modificationDate: nil)] {
        #expect(!token.accepts(key: key, expected: RenderKey(itemID: item, revision: changed, maximumPixelSize: 512), token: token))
    }
    #expect(!token.accepts(key: key, expected: key, token: PresentationToken(binding: UUID(), generation: token.generation)))
    #expect(!token.accepts(key: key, expected: key, token: PresentationToken(binding: token.binding, generation: UUID())))
}

@Test func previewAndViewportHaveDistinctRenderIdentitiesAtTheSameSize() {
    let key = RenderKey(itemID: ItemID.ephemeral(UUID()), revision: FileRevision(byteCount: 42, modificationDate: nil), maximumPixelSize: 512)
    let file = URL(fileURLWithPath: "/unused")
    let preview = ImageDecodeRequest(fileURL: file, maximumPixelSize: 512, renderKey: key, isPreview: true)
    let viewport = ImageDecodeRequest(fileURL: file, maximumPixelSize: 512, renderKey: key)
    #expect(preview.renderKey != viewport.renderKey)
    #expect(preview.renderKey?.isPreview == true)
    #expect(viewport.renderKey == key)
}
