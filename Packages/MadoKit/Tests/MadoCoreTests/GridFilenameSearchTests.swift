import Foundation
import Testing
@testable import MadoCore

@Test func gridFilenameSearchKeepsSortOrderAndIgnoresCaseAndAccents() {
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-search")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entries = ["zebra.jpg", "CAFÉ.png", "Café-2.heic", "other.jpg"].map {
        FolderEntry(url: folder.appendingPathComponent($0), root: root)
    }
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    let matched = snapshot.filteringFilename("cafe")
    #expect(matched.navigationEntries.map { $0.url.lastPathComponent } == ["Café-2.heic", "CAFÉ.png"])
    #expect(matched.version == snapshot.version)
    #expect(snapshot.navigationEntries.count == 4)
    #expect(snapshot.filteringFilename("absent").navigationEntries.isEmpty)
    #expect(snapshot.filteringFilename("").navigationEntries.count == 4)
}
