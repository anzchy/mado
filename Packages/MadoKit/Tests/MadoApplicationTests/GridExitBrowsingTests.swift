import Foundation
import Testing
import MadoCore
import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func openingIndependentImageLeavesGridBrowsingState() {
    let id = ItemID.ephemeral(UUID())
    let session = ViewerSession()
    session.beginBrowsing(items: [id], sourceVersion: .init(3), scrollAnchor: id)
    session.select(id)
    session.leaveBrowsing()
    #expect(session.mode == .viewing)
    #expect(session.previewSet == nil)
    #expect(session.selection == BrowserSelection())
    #expect(session.scrollAnchor == nil)
}
