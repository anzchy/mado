import Foundation
import Testing
import MadoCore

private let encodingItem = ItemID.ephemeral(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

@Test func renderKeyGoldenEncodings() {
    let missing = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42, modificationDate: nil), maximumPixelSize: 512)
    let dated = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42, modificationDate: Date(timeIntervalSinceReferenceDate: 1)), maximumPixelSize: 512)
    #expect(missing.stableEncoding == "rk1|id1:ephemeral:00000000-0000-0000-0000-000000000001|42|none|0|512|0|orientedSDR|1|viewer|none")
    #expect(dated.stableEncoding == "rk1|id1:ephemeral:00000000-0000-0000-0000-000000000001|42|3ff0000000000000|0|512|0|orientedSDR|1|viewer|none")
}

@Test func renderKeyEveryFieldChangesEncoding() {
    func key(item: ItemID = encodingItem, bytes: Int = 42, date: Date? = nil, frame: Int = 0,
             edge: Int = 512, preview: Bool = false, policy: RenderPolicy = .orientedSDR,
             version: Int = 1, purpose: RenderPurpose = .viewer) -> RenderKey {
        RenderKey(itemID: item, revision: FileRevision(byteCount: bytes, modificationDate: date),
                  maximumPixelSize: edge, isPreview: preview, frameIndex: frame, policy: policy,
                  decoderVersion: version, purpose: purpose)
    }
    let original = key()
    for changed in [key(item: ItemID.ephemeral(UUID())), key(bytes: 43),
                    key(date: Date(timeIntervalSinceReferenceDate: 1)), key(frame: 1), key(edge: 513),
                    key(preview: true), key(policy: .unorientedSDR), key(version: 2), key(purpose: .thumbnail)] {
        #expect(changed != original)
        #expect(changed.stableEncoding != original.stableEncoding)
    }
    #expect(key() == original)
    #expect(key().stableEncoding == original.stableEncoding)
    let advanced = key(frame: 3, policy: .unorientedSDR, version: 2, purpose: .thumbnail)
    let request = ImageDecodeRequest(fileURL: URL(fileURLWithPath: "/unused"), maximumPixelSize: 512, renderKey: advanced, isPreview: true)
    #expect(request.renderKey?.frameIndex == 3)
    #expect(request.renderKey?.policy == .unorientedSDR)
    #expect(request.renderKey?.decoderVersion == 2)
    #expect(request.renderKey?.purpose == .thumbnail)
}

@Test func renderKeyEqualDatesHaveEqualEncoding() {
    let positive = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42,
        modificationDate: Date(timeIntervalSinceReferenceDate: 0.0)), maximumPixelSize: 512)
    let negative = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42,
        modificationDate: Date(timeIntervalSinceReferenceDate: -0.0)), maximumPixelSize: 512)
    #expect(positive == negative)
    #expect(positive.stableEncoding == negative.stableEncoding)
}

@Test func renderKeyResourceRevisionChangesStableEncoding() {
    let original = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42, modificationDate: nil), maximumPixelSize: 512)
    let replacement = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42, modificationDate: nil,
        resourceIdentifier: "file1"), maximumPixelSize: 512)
    #expect(original != replacement)
    #expect(original.stableEncoding != replacement.stableEncoding)
    #expect(replacement.stableEncoding == "rk1|id1:ephemeral:00000000-0000-0000-0000-000000000001|42|none|0|512|0|orientedSDR|1|viewer|ZmlsZTE=")
}

@Test func renderKeyEquivalentUnicodeTokensEncodeEqually() {
    let composed = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42, modificationDate: nil,
        resourceIdentifier: "\u{00E9}"), maximumPixelSize: 512)
    let decomposed = RenderKey(itemID: encodingItem, revision: FileRevision(byteCount: 42, modificationDate: nil,
        resourceIdentifier: "e\u{0301}"), maximumPixelSize: 512)
    #expect(composed == decomposed)
    #expect(composed.stableEncoding == decomposed.stableEncoding)
    #expect(composed.stableEncoding == "rk1|id1:ephemeral:00000000-0000-0000-0000-000000000001|42|none|0|512|0|orientedSDR|1|viewer|w6k=")
}
