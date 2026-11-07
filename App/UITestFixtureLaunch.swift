import Foundation
import PicseeCore
import PicseeInfrastructure

/// Compiled only when the UI probe explicitly passes PICSEE_UI_TEST_FIXTURE.
enum UITestFixtureLaunch {
    static func fixtureName(arguments: [String]) -> String? {
        #if DEBUG && PICSEE_UI_TEST_FIXTURE
        guard let index = arguments.firstIndex(of: "-PicseeUITestFixture"),
              arguments.indices.contains(index + 1) else { return nil }
        let name = arguments[index + 1]
        guard !name.isEmpty, name.utf8.allSatisfy({ byte in
            (65...90).contains(Int(byte)) || (97...122).contains(Int(byte)) ||
            (48...57).contains(Int(byte)) || byte == 45
        }) else { return nil }
        return name
        #else
        return nil
        #endif
    }

    static func prepare(arguments: [String], environment: [String: String]) throws -> URL? {
        #if DEBUG && PICSEE_UI_TEST_FIXTURE
        guard let name = fixtureName(arguments: arguments) else { return nil }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Mado/UITestFixtures", isDirectory: true)
        return try stage(name: name, environment: environment, under: support)
        #else
        return nil
        #endif
    }

    #if DEBUG && PICSEE_UI_TEST_FIXTURE
    static func stage(name: String, environment: [String: String], under support: URL) throws -> URL {
        guard fixtureName(arguments: ["-PicseeUITestFixture", name]) != nil else { throw FixtureError.invalidName }
        let filenames = ["landscape-3x2.png", "portrait-2x3.png", "orientation-1.tiff"]
        let images = try filenames.indices.map { index -> Data in
            guard let encoded = environment["PICSEE_UI_FIXTURE_\(index)"],
                  let data = Data(base64Encoded: encoded) else { throw FixtureError.missingImage(index) }
            return data
        }
        let folder = support.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw FixtureError.folderAlreadyExists }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL ==
              support.resolvingSymlinksInPath().standardizedFileURL else { throw FixtureError.outsideContainer }
        for (index, filename) in filenames.enumerated() {
            try images[index].write(to: folder.appendingPathComponent(filename), options: .atomic)
        }
        return folder
    }

    static func removeRun(name: String, under support: URL) throws {
        guard fixtureName(arguments: ["-PicseeUITestFixture", name]) != nil else { throw FixtureError.invalidName }
        let folder = support.appendingPathComponent(name, isDirectory: true)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL ==
              support.resolvingSymlinksInPath().standardizedFileURL else { throw FixtureError.outsideContainer }
        try FileManager.default.removeItem(at: folder)
    }

    static func removeRun(folder: URL) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Mado/UITestFixtures", isDirectory: true)
        try removeRun(name: folder.lastPathComponent, under: support)
    }

    enum FixtureError: Error, Equatable { case invalidName, missingImage(Int), folderAlreadyExists, outsideContainer }
    #endif
}

#if DEBUG && PICSEE_UI_TEST_FIXTURE
/// Local-container authority for this isolated fixture run. It never extends the
/// OS sandbox and never writes to the production bookmark store.
struct UITestContainerAccess: SecurityScope, BookmarkCoding {
    let root: URL
    private let system = SystemSecurityScope()

    private func contains(_ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return path.starts(with: base)
    }

    func start(_ url: URL) -> Bool { contains(url) ? system.isReadable(url) : system.start(url) }
    func stop(_ url: URL) { if !contains(url) { system.stop(url) } }
    func isReadable(_ url: URL) -> Bool { system.isReadable(url) }
    func create(for url: URL) throws -> Data {
        guard contains(url) else { return try system.create(for: url) }
        return Data(url.standardizedFileURL.path.utf8)
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if let path = String(data: data, encoding: .utf8), path.hasPrefix("/"),
           contains(URL(fileURLWithPath: path)) {
            return ResolvedBookmark(url: URL(fileURLWithPath: path), stale: false)
        }
        return try system.resolve(data)
    }
}
#endif
