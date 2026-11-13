import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func gridSearchCurrentClearAndWindowReset() {
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-search-state")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let alpha = FolderEntry(url: folder.appendingPathComponent("alpha.jpg"), root: root)
    let beta = FolderEntry(url: folder.appendingPathComponent("beta.png"), root: root)
    let source = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [alpha, beta], isComplete: true)
    let search = GridSearchState()
    search.setTerm("beta", currentItemID: alpha.itemID)
    let filtered = search.project(source)
    #expect(filtered.navigationEntries.map(\.itemID) == [beta.itemID])
    #expect(search.currentItemID(in: filtered, currentItemID: alpha.itemID) == beta.itemID)
    search.setTerm("unmatched", currentItemID: beta.itemID)
    #expect(search.currentItemID(in: search.project(source), currentItemID: beta.itemID) == nil)
    search.clear()
    #expect(search.project(source).navigationEntries.count == 2)
    #expect(search.currentItemID(in: source, currentItemID: nil) == alpha.itemID)
    search.setTerm("beta", currentItemID: nil)
    let rescan = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 2),
        entries: [beta, alpha], isComplete: true)
    #expect(search.project(rescan).navigationEntries.map(\.itemID) == [beta.itemID])
    let otherWindow = GridSearchState()
    #expect(otherWindow.term.isEmpty)
    #expect(otherWindow.project(source).navigationEntries.count == 2)
    search.reset()
    #expect(search.term.isEmpty)
    #expect(search.preferredCurrentItemID == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func clearingSearchKeepsUserChosenMatchThenFallsBackWhenRemoved() {
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-search-chosen")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let before = FolderEntry(url: folder.appendingPathComponent("before.jpg"), root: root)
    let first = FolderEntry(url: folder.appendingPathComponent("match-1.jpg"), root: root)
    let chosen = FolderEntry(url: folder.appendingPathComponent("match-2.jpg"), root: root)
    let source = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [before, first, chosen], isComplete: true)
    let search = GridSearchState()
    search.setTerm("match", currentItemID: before.itemID)
    search.userChoseCurrentItem(chosen.itemID)
    search.clear()
    #expect(search.currentItemID(in: source, currentItemID: chosen.itemID) == chosen.itemID)

    search.setTerm("match", currentItemID: before.itemID)
    search.userChoseCurrentItem(chosen.itemID)
    search.clear()
    let removed = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 2),
        entries: [before, first], isComplete: true)
    #expect(search.currentItemID(in: removed, currentItemID: chosen.itemID) == before.itemID)
}
