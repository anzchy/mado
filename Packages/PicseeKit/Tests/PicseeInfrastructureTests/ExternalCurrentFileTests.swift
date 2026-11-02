import Foundation
import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeInfrastructure

@Test @MainActor func issue140RenameKeepsCurrentIdentityAndReplacementChangesRevision() async throws {
    let f = try WatchFixture(folders: ["root/F"]); defer { f.remove() }
    let root = f.url("root"), folder = f.url("root/F")
    let old = f.url("root/F/a.png"), renamed = f.url("root/F/z.png")
    do {
    let renamed = URL(fileURLWithPath: renamed.path.hasPrefix("/var/") ? "/private" + renamed.path : renamed.path)
    try Data(repeating: 1, count: 20).write(to: old)
    let rootID = try await f.access.grant(folder: root)
    let scanner = FolderBrowser()
    let coordinator = FolderScanCoordinator(access: f.access, scanner: scanner, watcher: f.hub)
    try await coordinator.begin(folder: folder, rootID: rootID).value
    let original = try #require(coordinator.currentItemID)
    try FileManager.default.moveItem(at: old, to: renamed)
    try await #require(coordinator.refresh()).value
    #expect(coordinator.currentItemID == original)
    #expect(coordinator.currentURL == renamed)

    try issue140PNG(red: 80).write(to: renamed)
    let pipeline = ImageIOPipeline()
    let rootIdentity = ItemIdentityRoot(id: rootID, url: root)
    let first = try await pipeline.request(for: renamed, maximumPixelSize: 64, identityRoot: rootIdentity)
    let before = try #require(first.renderKey)
    #expect(before.itemID == original)
    let replacement = f.url("root/F/new.png")
    try Data(repeating: 2, count: 20).write(to: replacement)
    try FileManager.default.removeItem(at: renamed)
    try FileManager.default.moveItem(at: replacement, to: renamed)
    try issue140PNG(red: 180).write(to: renamed)
    if let date = before.revision.modificationDate {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: renamed.path)
    }
    let after = try #require((try await pipeline.request(for: renamed, maximumPixelSize: 64,
        identityRoot: rootIdentity)).renderKey)
    #expect(after.itemID == before.itemID)
    #expect(after.revision != before.revision)
    let presentationBeforeRefresh = coordinator.presentationRevision
    try await #require(coordinator.refresh()).value
    #expect(coordinator.sourceSnapshot?.entries.first?.url == renamed)
    #expect(coordinator.presentationRevision > presentationBeforeRefresh)
    coordinator.end()
    }
}

private func issue140PNG(red: UInt8) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
    bitmap.setColor(NSColor(srgbRed: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@Test @MainActor func issue140MovedRootFollowsBookmarkAndDeletedCurrentChoosesNeighbor() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let root = f.url("root"), moved = f.url("moved")
    for name in ["a.png", "b.png", "c.png"] {
        try Data(repeating: 1, count: 3).write(to: root.appendingPathComponent(name))
    }
    let rootID = try await f.access.grant(folder: root)
    let coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    try await coordinator.begin(folder: root, rootID: rootID, input: root.appendingPathComponent("b.png")).value
    let current = try #require(coordinator.currentItemID)
    try FileManager.default.moveItem(at: root, to: moved)
    f.bookmarks.relocated = moved
    try await #require(coordinator.refresh()).value
    #expect(coordinator.currentItemID == current)
    #expect(coordinator.currentURL?.lastPathComponent == "b.png")
    #expect(coordinator.snapshot?.version.folder.lastPathComponent == "moved")
    try FileManager.default.removeItem(at: moved.appendingPathComponent("b.png"))
    try await #require(coordinator.refresh()).value
    #expect(coordinator.currentURL?.lastPathComponent == "c.png")
    try FileManager.default.removeItem(at: moved.appendingPathComponent("c.png"))
    try await #require(coordinator.refresh()).value
    #expect(coordinator.currentURL?.lastPathComponent == "a.png")
    try FileManager.default.removeItem(at: moved.appendingPathComponent("a.png"))
    try await #require(coordinator.refresh()).value
    #expect(coordinator.currentItemID == nil)
    #expect(coordinator.snapshot?.entries.isEmpty == true)
    coordinator.end()
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue140MovedRootRebasesSharedWatch() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let root = f.url("root"), moved = f.url("moved")
    try Data().write(to: root.appendingPathComponent("a.png"))
    let id = try await f.access.grant(folder: root)
    let coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    try await coordinator.begin(folder: root, rootID: id).value
    try FileManager.default.moveItem(at: root, to: moved)
    f.bookmarks.relocated = moved
    try await #require(coordinator.refresh()).value
    #expect(f.source.startURLs.last == canonicalPath(moved))
    let added = moved.appendingPathComponent("b.png")
    try Data().write(to: added)
    f.source.emit([.mustRescan], on: moved)
    f.clock.advance(by: 200)
    try await waitUntil {
        coordinator.snapshot?.entries.contains(where: { canonicalPath($0.url) == canonicalPath(added) }) == true
    }
    coordinator.end()
}

@Test @MainActor func issue140MovedRootRebasesNestedFolderWithoutEnumeratingParent() async throws {
    let f = try WatchFixture(folders: ["root/sub"]); defer { f.remove() }
    let root = f.url("root"), moved = f.url("moved")
    try Data().write(to: root.appendingPathComponent("sub/a.png"))
    let id = try await f.access.grant(folder: root)
    let coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    try await coordinator.begin(folder: root.appendingPathComponent("sub"), rootID: id).value
    try FileManager.default.moveItem(at: root, to: moved)
    f.bookmarks.relocated = moved
    try await #require(coordinator.refresh()).value
    #expect(coordinator.snapshot?.version.folder.lastPathComponent == "sub")
    #expect(coordinator.snapshot?.version.folder.deletingLastPathComponent().lastPathComponent == "moved")
    coordinator.end()
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue140MovedRootReconcilesOtherWindowOnSharedWatch() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let root = f.url("root"), moved = f.url("moved")
    try Data().write(to: root.appendingPathComponent("a.png"))
    let id = try await f.access.grant(folder: root)
    let first = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    let second = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    try await first.begin(folder: root, rootID: id).value
    try await second.begin(folder: root, rootID: id).value
    try FileManager.default.moveItem(at: root, to: moved)
    f.bookmarks.relocated = moved
    try await #require(first.refresh()).value
    try await waitUntil { second.snapshot?.version.folder.lastPathComponent == "moved" }
    first.end(); second.end()
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue140WatchedRenameKeepsCurrentUnderActiveExtensionFilter() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let root = f.url("root"), old = f.url("root/a.png"), renamed = f.url("root/z.png")
    try Data().write(to: old)
    try Data().write(to: f.url("root/b.jpg"))
    let rootID = try await f.access.grant(folder: root)
    let coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), watcher: f.hub)
    try await coordinator.begin(folder: root, rootID: rootID, input: old).value
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    let current = try #require(coordinator.currentItemID)
    try FileManager.default.moveItem(at: old, to: renamed)
    f.source.emit([.changed(old), .changed(renamed)], on: root)
    f.clock.advance(by: 200)
    try await waitUntil {
        coordinator.currentURL?.lastPathComponent == "z.png" &&
            coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["z.png"]
    }
    #expect(coordinator.currentItemID == current)
    #expect(coordinator.conditions.selectedExtensions == ["png"])
    #expect(coordinator.sourceSnapshot?.entries.count == 2)
    #expect(coordinator.snapshot?.isComplete == true)
    #expect(!coordinator.hasNoMatches)
    coordinator.end()
}
