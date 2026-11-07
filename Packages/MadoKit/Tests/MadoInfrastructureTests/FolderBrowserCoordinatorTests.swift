import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@Test @MainActor func folderBrowserCoordinatorRealLeaseIntegration() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("images")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    for name in ["img10.png", "img2.png"] { try Data().write(to: root.appendingPathComponent(name)) }
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "P2-02-WI-3")
    let id = try await access.grant(folder: root)
    #expect(scope.counts == [1, 1])
    let coordinator = FolderScanCoordinator(access: access, scanner: FolderBrowser())
    try await coordinator.begin(folder: root, rootID: id).value
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img2.png", "img10.png"])
    #expect(coordinator.snapshot?.entries.map(\.itemID) == [
        .rootRelative(rootID: id, relativePath: "img2.png"), .rootRelative(rootID: id, relativePath: "img10.png")])
    #expect(coordinator.snapshot?.isComplete == true)
    #expect(scope.counts == [2, 2])
    coordinator.end()
    #expect(coordinator.snapshot == nil)
    let missing = coordinator.begin(folder: root.appendingPathComponent("missing"), rootID: id)
    await #expect(throws: (any Error).self) { try await missing.value }
    #expect(coordinator.failure != nil)
    #expect(!coordinator.isReadingFolder)
    #expect(scope.counts == [3, 3])
    let empty = root.appendingPathComponent("empty")
    try fm.createDirectory(at: empty, withIntermediateDirectories: true)
    try await coordinator.begin(folder: empty, rootID: id).value
    #expect(coordinator.snapshot?.entries == [])
    #expect(coordinator.snapshot?.isComplete == true)
    #expect(scope.counts == [4, 4])
}

@Test @MainActor func realFolderScanMetadataAndFilterRoundTrip() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = base.appendingPathComponent("images")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let png = folder.appendingPathComponent("img2.PNG")
    let jpeg = folder.appendingPathComponent("img10.jpg")
    try Data(repeating: 1, count: 37).write(to: png)
    try Data(repeating: 2, count: 13).write(to: jpeg)
    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = Date(timeIntervalSince1970: 2_000_000)
    try fm.setAttributes([.modificationDate: early], ofItemAtPath: png.path)
    try fm.setAttributes([.modificationDate: late], ofItemAtPath: jpeg.path)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "P2-03-WI-1")
    let id = try await access.grant(folder: folder)
    let coordinator = FolderScanCoordinator(access: access, scanner: FolderBrowser())
    try await coordinator.begin(folder: folder, rootID: id, input: jpeg).value
    #expect(coordinator.sourceSnapshot?.entries.map(\.url.lastPathComponent) == ["img2.PNG", "img10.jpg"])
    #expect(coordinator.sourceSnapshot?.entries.map(\.fileSize) == [37, 13])
    #expect(coordinator.sourceSnapshot?.entries.map(\.modificationDate) == [early, late])
    coordinator.setConditions(.init(sort: .modificationDate, direction: .descending))
    #expect(coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["img10.jpg", "img2.PNG"])
    coordinator.setConditions(.init(sort: .size, selectedExtensions: ["pNg"]))
    #expect(coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["img2.PNG"])
    coordinator.setConditions(.init())
    #expect(coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["img2.PNG", "img10.jpg"])
    // Clearing a filter keeps the currently eligible PNG; it does not restore the excluded JPEG.
    #expect(coordinator.currentURL?.lastPathComponent == "img2.PNG")
    #expect(scope.counts == [2, 2])
}
