import Foundation
import Testing
import MadoCore
import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func gridProjectionPreservesIdentityAcrossGenerationsAndRejectsLateSnapshot() throws {
    let rootID = AccessRootID(rawValue: UUID())
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-projection")
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let a = FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: root)
    let b = FolderEntry(url: folder.appendingPathComponent("B.jpg"), root: root)
    let inserted = FolderEntry(url: folder.appendingPathComponent("0.jpg"), root: root)
    func snapshot(_ generation: UInt64, _ entries: [FolderEntry]) -> FolderSnapshot {
        FolderSnapshot(version: SnapshotVersion(rootID: rootID, folder: folder, generation: generation), entries: entries, isComplete: true)
    }
    let grid = FolderGridProjection()
    #expect(grid.apply(snapshot(8, [a, b])))
    grid.select(b.itemID)
    grid.setScrollAnchor(a.itemID)
    #expect(grid.apply(snapshot(9, [inserted, a, b])))
    #expect(grid.selectedItemID == b.itemID)
    #expect(grid.scrollAnchor == a.itemID)
    #expect(grid.entry(for: b.itemID)?.url == b.url)
    #expect(!grid.apply(snapshot(8, [a])))
    #expect(grid.selectedItemID == b.itemID)
    #expect(grid.apply(snapshot(10, [inserted, a])))
    #expect(grid.selectedItemID == nil)
    #expect(grid.scrollAnchor == a.itemID)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridProjectionDropsOldFolderIdentityOnRootChange() {
    let firstRoot = AccessRootID(rawValue: UUID())
    let secondRoot = AccessRootID(rawValue: UUID())
    let firstFolder = URL(fileURLWithPath: "/tmp/mado-grid-first")
    let secondFolder = URL(fileURLWithPath: "/tmp/mado-grid-second")
    let first = FolderEntry(url: firstFolder.appendingPathComponent("shared.jpg"),
        root: .init(id: firstRoot, url: firstFolder))
    let second = FolderEntry(url: secondFolder.appendingPathComponent("shared.jpg"),
        root: .init(id: secondRoot, url: secondFolder))
    let grid = FolderGridProjection()
    #expect(grid.apply(.init(version: .init(rootID: firstRoot, folder: firstFolder, generation: 9),
        entries: [first], isComplete: true)))
    grid.select(first.itemID)
    grid.setScrollAnchor(first.itemID)
    #expect(grid.apply(.init(version: .init(rootID: secondRoot, folder: secondFolder, generation: 1),
        entries: [second], isComplete: true)))
    #expect(grid.selectedItemID == nil)
    #expect(grid.scrollAnchor == nil)
    #expect(grid.entry(for: first.itemID) == nil)
}
