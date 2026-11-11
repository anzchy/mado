import Foundation
import Testing
import MadoCore

private let snapshotRoot = ItemIdentityRoot(id: AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000078")!),
    url: URL(fileURLWithPath: "/pictures"))
private func snapshotEntry(_ path: String) -> FolderEntry {
    FolderEntry(url: snapshotRoot.url.appendingPathComponent(path), root: snapshotRoot)
}
private let snapshotVersion = SnapshotVersion(rootID: snapshotRoot.id, folder: snapshotRoot.url, generation: 1)

@Test func folderSnapshotNaturalOrderAndTies() {
    let snapshot = FolderSnapshot(version: snapshotVersion,
        entries: [snapshotEntry("img10.png"), snapshotEntry("img2.png"), snapshotEntry("img1.png")], isComplete: false)
    #expect(snapshot.entries.map(\.url.lastPathComponent) == ["img1.png", "img2.png", "img10.png"])
    let ties = FolderSnapshot(version: snapshotVersion,
        entries: [snapshotEntry("b/img2.png"), snapshotEntry("a/img2.png")], isComplete: true)
    #expect(ties.entries.map(\.relativePath) == ["a/img2.png", "b/img2.png"])
    #expect(ties.entries.map(\.itemID) == [
        .rootRelative(rootID: snapshotRoot.id, relativePath: "a/img2.png"),
        .rootRelative(rootID: snapshotRoot.id, relativePath: "b/img2.png")])
}

@Test func folderSnapshotEmptySingletonAndVersion() {
    let empty = FolderSnapshot(version: snapshotVersion, entries: [], isComplete: false)
    #expect(empty.entries.isEmpty)
    #expect(!empty.isComplete)
    #expect(empty.version == snapshotVersion)
    let one = FolderSnapshot(version: snapshotVersion, entries: [snapshotEntry("img2.png")], isComplete: true)
    #expect(one.entries.map(\.relativePath) == ["img2.png"])
    #expect(one.isComplete)
    #expect(snapshotVersion == SnapshotVersion(rootID: snapshotRoot.id, folder: snapshotRoot.url, generation: 1))
    #expect(snapshotVersion != SnapshotVersion(rootID: AccessRootID(), folder: snapshotRoot.url, generation: 1))
    #expect(snapshotVersion != SnapshotVersion(rootID: snapshotRoot.id, folder: URL(fileURLWithPath: "/other"), generation: 1))
    #expect(snapshotVersion != SnapshotVersion(rootID: snapshotRoot.id, folder: snapshotRoot.url, generation: 2))
    #expect(snapshotVersion.folder == URL(fileURLWithPath: "/pictures"))
    #expect(snapshotVersion.rootID == snapshotRoot.id)
    #expect(snapshotVersion.generation == 1)
}

@Test func folderSnapshotBatchPartitionInvariant() {
    let expected = ["img1.png", "img2.png", "img10.png", "img20.png"]
    let partitions = [
        [["img20.png", "img2.png", "img10.png", "img1.png"]],
        [["img20.png"], ["img10.png"], ["img2.png"], ["img1.png"]],
        [["img10.png", "img1.png"], ["img20.png", "img2.png"]]]
    for batches in partitions {
        var snapshot = FolderSnapshot(version: snapshotVersion, entries: [], isComplete: false)
        let original = snapshot
        for batch in batches { snapshot = snapshot.appending(batch.map(snapshotEntry), isComplete: false) }
        let provisional = snapshot
        snapshot = snapshot.appending([], isComplete: true)
        #expect(snapshot.entries.map(\.relativePath) == expected)
        #expect(Set(snapshot.entries.map(\.itemID)).count == 4)
        #expect(snapshot.isComplete)
        #expect(original.entries.isEmpty && !original.isComplete)
        #expect(provisional.entries.map(\.relativePath) == expected && !provisional.isComplete)
    }
}

@Test func folderSnapshotEarlierInsertionPreservesIdentity() {
    let current = ItemID.rootRelative(rootID: snapshotRoot.id, relativePath: "img2.png")
    let first = FolderSnapshot(version: snapshotVersion,
        entries: [snapshotEntry("img2.png"), snapshotEntry("img10.png")], isComplete: false)
    let final = first.appending([snapshotEntry("img1.png")], isComplete: true)
    #expect(first.entries.first?.itemID == current)
    #expect(final.entries.firstIndex(where: { $0.itemID == current }) == 1)
    #expect(final.entries.dropFirst(2).first?.relativePath == "img10.png")
    #expect(final.entries.dropFirst().first?.itemID == current)
    #expect(first.entries.map(\.relativePath) == ["img2.png", "img10.png"])
}

@Test func issue358FolderSnapshotKeepsFirstNavigationEntryForDuplicateID() {
    let first = snapshotEntry("first.jpg")
    let second = snapshotEntry("second.jpg")
    let snapshot = FolderSnapshot(version: snapshotVersion, entries: [first, first, second], isComplete: true)
    #expect(snapshot.entries.count == 3)
    #expect(snapshot.navigationEntries.map(\.itemID) == [first.itemID, second.itemID])
    #expect(snapshot.navigationIndex(for: first.itemID) == 0)
    #expect(snapshot.navigationIndex(for: second.itemID) == 1)
}
