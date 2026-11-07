import Foundation
import Testing
import MadoCore

@Test func folderFixMergeCachedOrderPartitionInvariant() {
    let root = ItemIdentityRoot(id: AccessRootID(), url: URL(fileURLWithPath: "/merge-cache"))
    let version = SnapshotVersion(rootID: root.id, folder: root.url, generation: 7)
    let paths = ["img20.png", "b/img2.png", "img10.png", "a/img2.png", "img1.png"]
    let entries = paths.map { FolderEntry(url: root.url.appendingPathComponent($0), root: root) }
    let reference = FolderSnapshot(version: version, entries: entries, isComplete: true)
    #expect(reference.entries.map(\.relativePath) == ["img1.png", "a/img2.png", "b/img2.png", "img10.png", "img20.png"])
    // Exhaust every contiguous partition of both arrival directions, including empty batches.
    for order in [entries, Array(entries.reversed())] {
        for cuts in 0..<(1 << (entries.count - 1)) {
            var snapshot = FolderSnapshot(version: version, entries: [], isComplete: false)
            let original = snapshot
            var batch: [FolderEntry] = []
            for (index, entry) in order.enumerated() {
                batch.append(entry)
                if index == order.count - 1 || cuts & (1 << index) != 0 {
                    snapshot = snapshot.appending(batch, isComplete: false)
                    snapshot = snapshot.appending([], isComplete: false)
                    batch = []
                }
            }
            let prior = snapshot
            snapshot = snapshot.appending([], isComplete: true)
            #expect(snapshot.entries == reference.entries)
            #expect(snapshot.navigationEntries == reference.entries)
            #expect(snapshot.isComplete && !prior.isComplete && original.entries.isEmpty)
            #expect(prior.entries == reference.entries && prior.navigationEntries == reference.entries)
            for (index, entry) in snapshot.navigationEntries.enumerated() {
                #expect(snapshot.navigationIndex(for: entry.itemID) == index)
            }
            #expect(snapshot.navigationIndex(for: .ephemeral(UUID())) == nil)
        }
    }
}

@Test func folderFixMergeCachedAliasesChooseFirstNaturalRepresentative() throws {
    let fm = FileManager.default, folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let image = folder.appendingPathComponent("img2.png"), next = folder.appendingPathComponent("img10.png")
    let earlier = folder.appendingPathComponent("img0-alias.png"), later = folder.appendingPathComponent("z-alias.png")
    try Data().write(to: image); try Data().write(to: next)
    try fm.createSymbolicLink(at: earlier, withDestinationURL: image)
    try fm.createSymbolicLink(at: later, withDestinationURL: image)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let entry = { (url: URL) in FolderEntry(url: url, root: root) }
    let version = SnapshotVersion(rootID: root.id, folder: folder, generation: 1)
    let original = FolderSnapshot(version: version, entries: [entry(next), entry(image)], isComplete: false)
    let final = original.appending([entry(later), entry(earlier)], isComplete: true)
    #expect(final.entries.map(\.url.lastPathComponent) == ["img0-alias.png", "img2.png", "img10.png", "z-alias.png"])
    #expect(final.navigationEntries.map(\.url.lastPathComponent) == ["img0-alias.png", "img10.png"])
    #expect(final.navigationEntries.map(\.itemID) == [entry(image).itemID, entry(next).itemID])
    #expect(final.navigationIndex(for: entry(image).itemID) == 0)
    #expect(final.navigationIndex(for: entry(later).itemID) == 0)
    #expect(final.navigationIndex(for: entry(next).itemID) == 1)
    #expect(original.navigationEntries.map(\.url.lastPathComponent) == ["img2.png", "img10.png"])
    #expect(original.entries.count == 2 && !original.isComplete)
}
