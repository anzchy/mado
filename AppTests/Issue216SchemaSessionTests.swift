import Foundation
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

private struct Issue216Scope: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { true }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false)
    }
}

@Test(.timeLimit(.minutes(3))) func issue216AccessServicesGrantsForSessionOverFutureFiles() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let folder = base.appendingPathComponent("photos")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let rootPath = base.appendingPathComponent("roots.json")
    let recentPath = base.appendingPathComponent("recent.json")
    let future = Data(#"{"schemaVersion":99,"items":[{"future":true}]}"#.utf8)
    try future.write(to: rootPath)
    try future.write(to: recentPath)
    let adapter = Issue216Scope()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: rootPath), buildSHA: "issue216")
    let recent = RecentFolderStore(url: recentPath)
    let services = AccessServices(files: files, recent: recent, browser: FolderBrowser(),
        watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let id = try await services.grant(folder)
    #expect(await files.records().map(\.id) == [id])
    #expect(try await recent.load().map(\.rootID) == [id])
    #expect(try Data(contentsOf: rootPath) == future)
    #expect(try Data(contentsOf: recentPath) == future)
}
