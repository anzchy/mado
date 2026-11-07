import Foundation
import Testing

#if !DEBUG || !PICSEE_UI_TEST_FIXTURE
@Test func fixtureLaunchArgumentIsIgnoredWithoutTestBuildFlag() throws {
    #expect(UITestFixtureLaunch.fixtureName(arguments: ["-MadoUITestFixture", "three-images"]) == nil)
    #expect(try UITestFixtureLaunch.prepare(arguments: ["-MadoUITestFixture", "three-images"],
        environment: [:]) == nil)
}
#endif

#if DEBUG && PICSEE_UI_TEST_FIXTURE
@Test func fixtureLaunchAcceptsOnlyOnePathComponent() {
    #expect(UITestFixtureLaunch.fixtureName(arguments: ["-MadoUITestFixture", "three-images"]) == "three-images")
    for name in ["", "../outside", "/tmp/outside", "a/b", "a\\b", ".", "..", "汉字"] {
        #expect(UITestFixtureLaunch.fixtureName(arguments: ["-MadoUITestFixture", name]) == nil)
    }
    #expect(UITestFixtureLaunch.fixtureName(arguments: ["-MadoUITestFixture"]) == nil)
}

@Test func fixtureStageWritesOnlyThreePinnedFilesAndRefusesReuse() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = [Data([1]), Data([2]), Data([3])]
    let environment: [String: String] = Dictionary(uniqueKeysWithValues: bytes.enumerated().map {
        ("PICSEE_UI_FIXTURE_\($0.offset)", $0.element.base64EncodedString())
    })
    let folder = try UITestFixtureLaunch.stage(name: "three-images", environment: environment, under: root)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == ["landscape-3x2.png", "orientation-1.tiff", "portrait-2x3.png"])
    #expect(try Data(contentsOf: folder.appendingPathComponent("portrait-2x3.png")) == bytes[1])

    do {
        _ = try UITestFixtureLaunch.stage(name: "three-images", environment: environment, under: root)
        Issue.record("An existing fixture directory was reused")
    } catch {
        #expect(error as? UITestFixtureLaunch.FixtureError == .folderAlreadyExists)
    }
    do {
        _ = try UITestFixtureLaunch.stage(name: "../outside", environment: environment, under: root)
        Issue.record("A traversal name was accepted")
    } catch {
        #expect(error as? UITestFixtureLaunch.FixtureError == .invalidName)
    }
    do {
        _ = try UITestFixtureLaunch.stage(name: "missing-images", environment: [:], under: root)
        Issue.record("Missing fixture bytes were accepted")
    } catch {
        #expect(error as? UITestFixtureLaunch.FixtureError == .missingImage(0))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing-images").path))
    #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent()
        .appendingPathComponent("outside").path))
}

@Test func fixtureCleanupRemovesOnlyTheNamedRun() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let first = support.appendingPathComponent("run-one", isDirectory: true)
    let second = support.appendingPathComponent("run-two", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    try UITestFixtureLaunch.removeRun(name: "run-one", under: support)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
}
#endif
