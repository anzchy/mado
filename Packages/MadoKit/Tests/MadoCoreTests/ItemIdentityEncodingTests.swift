import Foundation
import Testing
import MadoCore

@Test func itemIdentityFormsAreVersionedStrings() throws {
    let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let root = AccessRootID(rawValue: uuid)
    let examples: [(ItemID, String)] = [
        (.ephemeral(uuid), "id1:ephemeral:00000000-0000-0000-0000-000000000001"),
        (.resource(volumeUUID: "VOL", fileIdentifier: "42"), "id1:res:Vk9M:NDI="),
        (.rootRelative(rootID: root, relativePath: "a/../b.png"), "id1:root:00000000-0000-0000-0000-000000000001:Yi5wbmc=")
    ]
    for (item, expected) in examples {
        #expect(item.stableEncoding == expected)
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(String.self, from: data) == expected)
        #expect(try JSONDecoder().decode(ItemID.self, from: data) == item)
    }
    #expect(ItemID.rootRelative(rootID: root, relativePath: "b.png") == examples[2].0)
    #expect(ItemID.resource(volumeUUID: "VOL", fileIdentifier: "42") == examples[1].0)
    #expect(Set(examples.map(\.0)).count == 3)
}

@Test func itemIdentityRejectsInvalidPersistentStrings() throws {
    for value in ["id2:ephemeral:00000000-0000-0000-0000-000000000001", "id1:ephemeral:bad", "id1:other:a",
                  "id1:res:?:NDI=", "id1:root:bad:Yi5wbmc=", "id1:root:00000000-0000-0000-0000-000000000001:?"] {
        let data = try JSONEncoder().encode(value)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ItemID.self, from: data) }
    }
}
