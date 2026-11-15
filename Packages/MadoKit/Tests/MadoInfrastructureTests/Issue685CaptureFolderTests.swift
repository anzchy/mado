import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #685 AC-5: the folder record persists across relaunch, the writer uses the resolved folder with the #682 naming and
// exclusive create, and a real security-scoped bookmark of a chosen folder resolves in a new instance.

@Test(.timeLimit(.minutes(2))) func issue685CaptureFolderRecordPersistsAcrossInstances() async throws {
    let name = "issue685-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let helper = UserDefaultsCaptureFolderPreferences(defaults: defaults)
    #expect(await helper.folderRecord() == .downloads)
    let record = CaptureFolderRecord(bookmark: Data([1, 2, 3]), display: "~/Pictures", fellBack: true)
    await helper.setFolderRecord(record)
    let settings = UserDefaultsCaptureFolderPreferences(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(await settings.folderRecord() == record)
    await settings.setFolderRecord(.downloads)
    #expect(await helper.folderRecord() == .downloads)
    #expect(defaults.object(forKey: UserDefaultsCaptureFolderPreferences.bookmarkKey) == nil)
    #expect(UserDefaultsCaptureFolderPreferences.bookmarkKey == "capture.folder.bookmark.v1")
    #expect(UserDefaultsCaptureFolderPreferences.displayKey == "capture.folder.display.v1")
    #expect(UserDefaultsCaptureFolderPreferences.fallbackKey == "capture.folder.fallback.v1")
    #expect(UserDefaultsCaptureFolderPreferences.shared() != nil)
}

@Test(.timeLimit(.minutes(2))) func issue685WriterUsesTheResolvedFolderWithExclusiveCreate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue685-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = DownloadsCaptureFilePort(folder: { root }, display: { "~/Shots" })
    #expect(await files.folderDisplay() == "~/Shots")
    let url = try await files.writeNewPNG(Data([7]), named: "mado-20261114120000.png")
    #expect(url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    #expect(try Data(contentsOf: url) == Data([7]))
    await #expect(throws: CaptureFileError.alreadyExists) {
        try await files.writeNewPNG(Data([8]), named: "mado-20261114120000.png")
    }
    #expect(try Data(contentsOf: url) == Data([7]))
    #expect(await DownloadsCaptureFilePort(directory: root).folderDisplay() == nil)
    // #682 naming continues in the chosen folder.
    let session = CaptureSession(screen: Pixel(), files: files, now: { Date(timeIntervalSince1970: 0) },
                                 timeZone: TimeZone(identifier: "UTC"))
    let saved = try await session.capture()
    let second = try await session.capture()
    #expect(saved.lastPathComponent == "mado-19700101000000.png")
    #expect(second.lastPathComponent == "mado-19700101000000-2.png")
    #expect(second.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
}

private struct Pixel: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data([1]) }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data([1]) }
}

@Test(.timeLimit(.minutes(2))) func issue685RealBookmarkOfAChosenFolderResolvesAfterRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue685-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let name = "issue685-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let downloads = FileManager.default.temporaryDirectory
    let first = CaptureFolderAccess(scope: SystemSecurityScope(), preferences: UserDefaultsCaptureFolderPreferences(defaults: defaults),
                                    downloads: downloads, home: URL(fileURLWithPath: NSHomeDirectory()))
    try await first.choose(root)
    let relaunched = CaptureFolderAccess(
        scope: SystemSecurityScope(),
        preferences: UserDefaultsCaptureFolderPreferences(defaults: try #require(UserDefaults(suiteName: name))),
        downloads: downloads, home: URL(fileURLWithPath: NSHomeDirectory()))
    let resolved = await relaunched.currentFolder()
    #expect(resolved.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
    #expect(await UserDefaultsCaptureFolderPreferences(defaults: defaults).folderRecord().fellBack == false)
}
