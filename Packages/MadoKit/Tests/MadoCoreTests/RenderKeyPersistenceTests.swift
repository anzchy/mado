import Foundation
import Testing
import MadoCore

@Test func renderKeyPersistenceRejectsSessionTokens() {
    let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let root = ItemID.rootRelative(rootID: AccessRootID(rawValue: uuid), relativePath: "b.png")
    let resource = ItemID.resource(volumeUUID: "VOL", fileIdentifier: "session-1")
    func key(_ item: ItemID, token: String? = nil) -> RenderKey {
        RenderKey(itemID: item, revision: FileRevision(byteCount: 42, modificationDate: nil,
            resourceIdentifier: token), maximumPixelSize: 512)
    }
    #expect(key(resource).persistentEncoding == nil)
    #expect(key(.ephemeral(uuid)).persistentEncoding == nil)
    // Dropping this token would alias same-size/same-time replacements, so refuse persistence instead.
    #expect(key(root, token: "session-1").persistentEncoding == nil)
    #expect(key(root, token: "session-2").persistentEncoding == nil)
    #expect(key(root, token: "session-1").stableEncoding != key(root, token: "session-2").stableEncoding)
    #expect(key(root).persistentEncoding == "rkp1|id1:root:00000000-0000-0000-0000-000000000001:Yi5wbmc=|42|none|0|512|0|orientedSDR|1|viewer|none")
    let restored = ItemID.rootRelative(rootID: AccessRootID(rawValue: uuid), relativePath: "./b.png")
    #expect(key(root).persistentEncoding == key(restored).persistentEncoding)
}
