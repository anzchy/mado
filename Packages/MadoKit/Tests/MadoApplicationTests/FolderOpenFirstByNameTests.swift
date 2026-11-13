import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class FolderOpenFirstByNameHost: FolderScanHost {
    var opens: [URL] = []
    var remembered: [URL] = []

    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { remembered.append(folder) }
}

@Suite @MainActor struct FolderOpenFirstByNameTests {
    @Test(.timeLimit(.minutes(2))) func folderOpenWaitsForCompletionThenOpensNameFirst() async throws {
        let fixture = FolderScanFixture(), host = FolderOpenFirstByNameHost()
        fixture.coordinator.host = host
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)

        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["img-0040.png", "img-0050.png"])
        #expect(fixture.coordinator.isReadingFolder)
        #expect(fixture.coordinator.snapshot?.isComplete == false)
        #expect(fixture.coordinator.currentURL == nil)
        #expect(host.opens.isEmpty && host.remembered.isEmpty)

        try await fixture.scanner.deliver(["img-0300.png", "img-0001.png"])
        #expect(fixture.coordinator.isReadingFolder)
        #expect(host.opens.isEmpty && host.remembered.isEmpty)

        await fixture.scanner.finish()
        try await task.value
        let expected = fixture.folder.appendingPathComponent("img-0001.png")
        #expect(host.opens == [expected])
        #expect(host.remembered == [fixture.folder])
        #expect(fixture.coordinator.currentURL == expected)
        #expect(fixture.coordinator.currentItemID == .rootRelative(rootID: fixture.id, relativePath: "A/img-0001.png"))
        #expect(!fixture.coordinator.isReadingFolder)
        #expect(fixture.coordinator.snapshot?.isComplete == true)
        #expect(await fixture.access.balance == [1, 1])
    }

    @Test(.timeLimit(.minutes(2))) func inputOpenPublishesInputImmediatelyAndNeverChoosesFolderFirst() async throws {
        let fixture = FolderScanFixture(), host = FolderOpenFirstByNameHost()
        fixture.coordinator.host = host
        let input = fixture.folder.appendingPathComponent("img-0040.png")
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)

        #expect(!fixture.coordinator.isReadingFolder)
        #expect(fixture.coordinator.currentURL == input)
        #expect(fixture.coordinator.currentItemID == nil)
        await fixture.scanner.waitForStart()
        #expect(fixture.coordinator.currentItemID == input.folderItemID(rootID: fixture.id, root: fixture.root))
        try await fixture.scanner.deliver(["img-0001.png"])
        #expect(fixture.coordinator.currentURL == input)
        #expect(host.opens.isEmpty && host.remembered.isEmpty)
        await fixture.scanner.finish()
        try await task.value
        #expect(fixture.coordinator.currentURL == input)
        #expect(host.opens.isEmpty && host.remembered.isEmpty)
        #expect(await fixture.access.balance == [1, 1])
    }

    @Test(.timeLimit(.minutes(2))) func emptyFolderShowsEmptyOnlyAfterCompletion() async throws {
        let fixture = FolderScanFixture(), host = FolderOpenFirstByNameHost()
        fixture.coordinator.host = host
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)

        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver([])
        #expect(fixture.coordinator.isReadingFolder)
        #expect(!fixture.coordinator.isEmptyFolder)
        await fixture.scanner.finish()
        try await task.value
        #expect(!fixture.coordinator.isReadingFolder)
        #expect(fixture.coordinator.isEmptyFolder)
        #expect(host.opens.isEmpty && host.remembered.isEmpty)
        #expect(await fixture.access.balance == [1, 1])
    }

    @Test(.timeLimit(.minutes(2))) func cancelDuringReadingRejectsLateCompletion() async throws {
        let fixture = FolderScanFixture(), host = FolderOpenFirstByNameHost()
        fixture.coordinator.host = host
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)

        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["img-0040.png"])
        fixture.coordinator.cancel()
        await fixture.scanner.finish()
        try await task.value
        #expect(host.opens.isEmpty && host.remembered.isEmpty && !fixture.coordinator.isEmptyFolder)
        #expect(fixture.coordinator.snapshot == nil)
        #expect(fixture.coordinator.currentURL == nil)
        #expect(!fixture.coordinator.isReadingFolder)
        #expect(await fixture.access.balance == [1, 1])
    }

    @Test(.timeLimit(.minutes(2))) func failureAfterBatchKeepsPartialSnapshotWithoutOpening() async throws {
        let fixture = FolderScanFixture(), host = FolderOpenFirstByNameHost()
        fixture.coordinator.host = host
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)

        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["img-0040.png"])
        await fixture.scanner.finish(failing: true)
        await #expect(throws: FolderScanTestError.expected) { try await task.value }
        #expect(host.opens.isEmpty && host.remembered.isEmpty && !fixture.coordinator.isEmptyFolder)
        #expect(fixture.coordinator.failure is FolderScanTestError)
        // #238: a folder-entry failure keeps no partial snapshot (24F-A shows no partial list).
        #expect(fixture.coordinator.snapshot == nil && fixture.coordinator.sourceSnapshot == nil)
        #expect(!fixture.coordinator.isReadingFolder)
        #expect(await fixture.access.balance == [1, 1])
    }

    @Test(.timeLimit(.minutes(2))) func supersededFolderScanCannotOpenAfterCompletion() async throws {
        let fixture = FolderScanFixture(), host = FolderOpenFirstByNameHost()
        fixture.coordinator.host = host
        let old = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["img-0040.png"])

        let replacementFolder = fixture.root.appendingPathComponent("B")
        let replacement = fixture.coordinator.begin(folder: replacementFolder, rootID: fixture.id)
        await fixture.scanner.waitForStart(1)
        try await fixture.scanner.deliver(["img-0050.png"], at: 1)
        await fixture.scanner.finish()
        try await old.value
        #expect(host.opens.isEmpty && host.remembered.isEmpty)

        try await fixture.scanner.deliver(["img-0001.png"], at: 1)
        await fixture.scanner.finish(1)
        try await replacement.value
        #expect(host.opens == [replacementFolder.appendingPathComponent("img-0001.png")])
        #expect(host.remembered == [replacementFolder])
        #expect(fixture.coordinator.generation == 2)
        #expect(await fixture.access.balance == [2, 2])
    }
}

private extension URL {
    func folderItemID(rootID: AccessRootID, root: URL) -> ItemID {
        FolderEntry(url: self, root: ItemIdentityRoot(id: rootID, url: root)).itemID
    }
}
