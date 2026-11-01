import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

@MainActor private func i142CompletedScan() async throws -> FolderScanFixture {
    let f = FolderScanFixture()
    let task = f.coordinator.begin(folder: f.folder, rootID: f.id)
    await f.scanner.waitForStart()
    try await f.scanner.deliver(["a.png", "b.jpg", "c.png"])
    await f.scanner.finish()
    try await task.value
    return f
}

@Test @MainActor func i142WI2CompletedCountFollowsFilterRoundTrip() async throws {
    let f = try await i142CompletedScan(), c = f.coordinator
    for (extensions, names) in [
        (nil as Set<String>?, ["a.png", "b.jpg", "c.png"]),
        (["png"], ["a.png", "c.png"]), (["gif"], []),
        (nil, ["a.png", "b.jpg", "c.png"])
    ] {
        c.setConditions(.init(selectedExtensions: extensions))
        #expect(c.snapshot?.navigationEntries.map(\.url.lastPathComponent) == names)
        #expect(c.completedImageCount == names.count)
        #expect(c.completedImageCount == c.snapshot?.navigationEntries.count)
        #expect(c.sourceSnapshot?.navigationEntries.count == 3)
    }
}

@Test(arguments: ["folder-complete", "folder-failed", "image-failed"])
@MainActor func i142WI2UnknownAndFailureCountsStayNil(ending: String) async throws {
    let f = FolderScanFixture(holdsAcquire: true), c = f.coordinator
    #expect(c.completedImageCount == nil)
    let input = ending == "image-failed" ? f.folder.appendingPathComponent("a.png") : nil
    let task = c.begin(folder: f.folder, rootID: f.id, input: input)
    await f.access.waitForHeldAcquisition()
    #expect(c.completedImageCount == nil)
    await f.access.resumeAcquisition()
    await f.scanner.waitForStart()
    try await f.scanner.deliver(["a.png", "b.jpg"])
    #expect(c.snapshot?.isComplete == false)
    #expect(c.completedImageCount == nil)
    let failed = ending != "folder-complete"
    await f.scanner.finish(failing: failed)
    if failed {
        await #expect(throws: FolderScanTestError.expected) { try await task.value }
        #expect(c.failure != nil)
        #expect(c.completedImageCount == nil)
        if input != nil { #expect(c.snapshot?.navigationEntries.count == 2) }
    } else {
        try await task.value
        #expect(c.completedImageCount == 2)
        #expect(c.snapshot?.isComplete == true)
    }
    #expect(!c.isScanning)
}

@Test @MainActor func i142WI2CancelRestoresFilteredCountAndRejectsLateEvents() async throws {
    let f = try await i142CompletedScan(), c = f.coordinator, session = ViewerSession()
    session.folderScan = c
    c.setConditions(.init(selectedExtensions: ["png"]))
    let prior = try #require(c.snapshot)
    session.enterFolderGrid(items: prior.navigationEntries.map(\.itemID), sourceVersion: .init(1))
    session.beginFolderEntry(shownImage: nil, hasCompleteGrid: true)
    let replacement = c.begin(folder: f.root.appendingPathComponent("B"), rootID: f.id)
    await f.scanner.waitForStart(1)
    try await f.scanner.deliver(["replacement.png"], at: 1)
    #expect(c.completedImageCount == nil)
    #expect(session.cancelFolderEntry() == .grid)
    #expect(!c.isScanning && !c.isReadingFolder)
    #expect(c.snapshot == prior)
    #expect(c.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["a.png", "c.png"])
    #expect(c.completedImageCount == 2)
    try await f.scanner.deliver(["late.png"], at: 1)
    await f.scanner.finish(1)
    try await replacement.value
    #expect(c.snapshot == prior)
    #expect(c.completedImageCount == 2)
}

@Test @MainActor func i142WI2SilentRefreshKeepsCountUntilFailureThenRecovers() async throws {
    let f = try await i142CompletedScan(), c = f.coordinator
    c.setConditions(.init(selectedExtensions: ["png"]))
    let prior = try #require(c.snapshot)
    let failed = try #require(c.refresh())
    await f.scanner.waitForStart(1)
    try await f.scanner.deliver(["new.png"], at: 1)
    #expect(c.snapshot == prior)
    #expect(c.completedImageCount == 2)
    #expect(!c.isReadingFolder && !c.isScanning)
    await f.scanner.finish(1, failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await failed.value }
    #expect(c.sourceSnapshot?.isComplete == true)
    #expect(c.completedImageCount == nil && c.failure != nil)
    let recovered = try #require(c.refresh())
    await f.scanner.waitForStart(2)
    try await f.scanner.deliver(["new.png", "excluded.jpg"], at: 2)
    await f.scanner.finish(2)
    try await recovered.value
    #expect(c.failure == nil)
    #expect(c.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["new.png"])
    #expect(c.completedImageCount == 1)
}
