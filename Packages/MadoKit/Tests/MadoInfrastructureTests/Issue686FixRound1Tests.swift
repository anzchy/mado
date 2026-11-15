import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #686 P7-10 CAP-02 fix round 1, F1: with no Capture Folder value in the App Group, no folder is the Capture Folder;
// an image in ~/Downloads gets the generic wording. Once the helper publishes a value, that folder gets capture wording.

@MainActor @Test(.timeLimit(.minutes(2))) func issue686MissingAppGroupValueMeansNoCaptureFolder() async throws {
    let name = "issue686-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = UserDefaultsCaptureFolderPreferences(defaults: defaults)
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
    let shots = home.appendingPathComponent("Pictures/Shots", isDirectory: true)
    let gate = CaptureFolderGrantGate(record: { await preferences.publishedFolderRecord() }, home: home)

    #expect(await preferences.publishedFolderRecord() == nil)
    #expect(await preferences.folderRecord() == .downloads, "Settings still shows ~/Downloads")
    #expect(await gate.paging(in: downloads) == .prompt(.generic))

    await preferences.setFolderRecord(.downloads)
    #expect(await preferences.publishedFolderRecord() == .downloads)
    #expect(await gate.paging(in: downloads) == .prompt(.capture))

    let chosen = CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: false)
    await preferences.setFolderRecord(chosen)
    #expect(await preferences.publishedFolderRecord() == chosen)
    #expect(await gate.paging(in: shots) == .prompt(.capture))
    #expect(await gate.paging(in: downloads) == .prompt(.generic))
}
