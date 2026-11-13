import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func latestSearchProjectionWinsAndCancelSuppressesOldResult() async throws {
    let folder = URL(fileURLWithPath: "/tmp/mado-search-scheduler")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let first = FolderEntry(url: folder.appendingPathComponent("alpha.jpg"), root: root)
    let second = FolderEntry(url: folder.appendingPathComponent("beta.jpg"), root: root)
    let source = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [first, second], isComplete: true)
    let scheduler = GridSearchProjectionScheduler()
    var delivered: [[ItemID]] = []
    scheduler.schedule(source, term: "alpha") { delivered.append($0.navigationEntries.map(\.itemID)) }
    scheduler.schedule(source, term: "beta") { delivered.append($0.navigationEntries.map(\.itemID)) }
    try await Task.sleep(for: .milliseconds(300))
    await scheduler.waitForPending()
    #expect(delivered == [[second.itemID]])
    scheduler.schedule(source, term: "alpha") { delivered.append($0.navigationEntries.map(\.itemID)) }
    scheduler.cancel()
    try await Task.sleep(for: .milliseconds(200))
    #expect(delivered == [[second.itemID]])
}
