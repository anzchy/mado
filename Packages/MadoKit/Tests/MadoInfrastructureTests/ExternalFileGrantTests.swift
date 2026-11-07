import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@Test func issue140FileGrantBookmarkFollowsRenameAndRefreshesStaleData() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let original = f.url("root/old.png"), renamed = f.url("root/new.png")
    try Data(repeating: 1, count: 4).write(to: original)
    let lease = try await f.access.acquire(.fileGrant(original))
    await f.access.release(lease)
    let created = f.bookmarks.count
    try FileManager.default.moveItem(at: original, to: renamed)
    f.bookmarks.relocated = renamed
    f.bookmarks.stale = true
    #expect(try await f.access.resolveFileGrant(original) == renamed)
    #expect(f.bookmarks.count > created)
    let movedLease = try await f.access.acquire(.fileGrant(original))
    #expect(movedLease.url == renamed)
    await f.access.release(movedLease)
    #expect(await f.access.records().isEmpty)
    f.bookmarks.fails = true
    await #expect(throws: FileAccessError.needsFileReconnection(original)) {
        _ = try await f.access.resolveFileGrant(original)
    }
}

@Test func issue140FileGrantSourceUsesRenamedFileAndReplacementPixels() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let original = f.url("root/old.png"), renamed = f.url("root/new.png")
    try FileManager.default.copyItem(at: fixture("landscape-3x2.png"), to: original)
    let source = try await AccessImageSource.open(.fileGrant(original), access: f.access,
        pipeline: ImageIOPipeline())
    let (oldRequest, oldImage) = try await source.image(maximumPixelSize: 64)
    try FileManager.default.moveItem(at: original, to: renamed)
    f.bookmarks.relocated = renamed
    let (renamedRequest, renamedImage) = try await source.image(maximumPixelSize: 64)
    #expect(renamedRequest.fileURL == renamed)
    #expect(renamedImage.itemID == oldImage.itemID)
    #expect(try rgba(renamedImage.image) == rgba(oldImage.image))
    try Data(contentsOf: fixture("portrait-2x3.png")).write(to: renamed, options: .atomic)
    let (replacementRequest, replacementImage) = try await source.image(maximumPixelSize: 64)
    #expect(replacementRequest.renderKey?.revision != oldRequest.renderKey?.revision)
    #expect(try rgba(replacementImage.image) != rgba(oldImage.image))
    await source.close()
}

@Test func issue140FileGrantRenameWinsWhenVacatedNameIsReused() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let original = f.url("root/old.png"), renamed = f.url("root/new.png")
    try Data(repeating: 1, count: 3).write(to: original)
    let lease = try await f.access.acquire(.fileGrant(original))
    await f.access.release(lease)
    try FileManager.default.moveItem(at: original, to: renamed)
    try Data(repeating: 2, count: 3).write(to: original)
    f.bookmarks.relocated = renamed
    #expect(try await f.access.resolveFileGrant(original) == renamed)
}

@Test func issue140SingleFileSamePathAtomicReplacementShowsNewPixels() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let file = f.url("root/image.png")
    try FileManager.default.copyItem(at: fixture("landscape-3x2.png"), to: file)
    let source = try await AccessImageSource.open(.fileGrant(file), access: f.access,
        pipeline: ImageIOPipeline())
    let (oldRequest, oldImage) = try await source.image(maximumPixelSize: 64)
    try Data(contentsOf: fixture("portrait-2x3.png")).write(to: file, options: .atomic)
    let (newRequest, newImage) = try await source.image(maximumPixelSize: 64)
    #expect(newRequest.renderKey?.itemID == oldRequest.renderKey?.itemID)
    #expect(newRequest.renderKey?.revision != oldRequest.renderKey?.revision)
    #expect(try rgba(newImage.image) != rgba(oldImage.image))
    await source.close()
}

@Test func issue140ExistingFileGrantBookmarkReportsScopeLossForReconnection() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let file = f.url("root/image.png")
    try Data(repeating: 1, count: 4).write(to: file)
    let lease = try await f.access.acquire(.fileGrant(file))
    await f.access.release(lease)
    f.scope.succeeds = false
    await #expect(throws: FileAccessError.needsFileReconnection(file)) {
        _ = try await f.access.acquire(.fileGrant(file))
    }
}

private actor NoRelocationLease: AccessLeasing {
    func acquire(_ request: AccessRequest) async throws -> AccessLease { throw FileAccessError.startFailed }
    func release(_ lease: AccessLease) async {}
}

@Test func issue140RealFileGrantTrashIsDeletion() async throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let original = directory.appendingPathComponent("trashed.png")
    try Data([1, 2, 3]).write(to: original)
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: directory.appendingPathComponent("roots.json")), buildSHA: "issue140-trash")
    let lease = try await access.acquire(.fileGrant(original))
    await access.release(lease)
    var trashed: NSURL?
    try fm.trashItem(at: original, resultingItemURL: &trashed)
    defer { if let trashed { try? fm.removeItem(at: trashed as URL) } }
    await #expect(throws: FileAccessError.fileDeleted(original)) {
        _ = try await access.resolveFileGrant(original)
    }
}

@Test func issue140TrashClassifierUsesActualVolumeLocationWithoutNearPrefix() throws {
    let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
        appropriateFor: FileManager.default.temporaryDirectory, create: false)
    #expect(FileAccess.isTrashed(trash))
    let volume = URL(fileURLWithPath: "/Volumes/fixture")
    #expect(FileAccess.isInPerUserVolumeTrash(
        URL(fileURLWithPath: "/Volumes/fixture/.Trashes/501/image.png"), volume: volume, uid: 501))
    #expect(!FileAccess.isInPerUserVolumeTrash(
        URL(fileURLWithPath: "/Volumes/fixture/ordinary/.Trashes/501/image.png"), volume: volume, uid: 501))
    #expect(!FileAccess.isInPerUserVolumeTrash(
        URL(fileURLWithPath: "/Volumes/fixture/.Trashes/502/image.png"), volume: volume, uid: 501))
    #expect(!FileAccess.isTrashed(URL(fileURLWithPath: "/Users/someone/.Trash/image.png")))
    #expect(!FileAccess.isTrashed(URL(fileURLWithPath: "/tmp/ordinary/.Trashes/501/image.png")))
    #expect(!FileAccess.isTrashed(URL(fileURLWithPath: "/Volumes/other/.Trashes-near/image.png")))
}

@Test func issue140OtherAccessLeasesHaveNoImplicitFolderRelocation() async throws {
    #expect(try await NoRelocationLease().relocatedFolder(URL(fileURLWithPath: "/tmp"),
        rootID: AccessRootID()) == nil)
}
