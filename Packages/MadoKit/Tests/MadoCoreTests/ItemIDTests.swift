import Foundation
import Testing
import MadoCore

@Test func itemIDSurvivesJSONRoundTrip() throws {
    let original = ItemID.ephemeral(UUID(uuidString: "2FA253B4-18A7-4F30-9629-7D53DF089649")!)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ItemID.self, from: encoded)
    #expect(decoded == original)
}
