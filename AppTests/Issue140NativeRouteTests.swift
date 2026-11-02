import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

private struct Issue140Bookmarks: SecurityScope, BookmarkCoding {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        guard let path = String(data: data, encoding: .utf8) else { throw FileAccessError.corruptStore }
        return ResolvedBookmark(url: URL(fileURLWithPath: path), stale: false)
    }
}

@MainActor private final class Issue140ScanTrace: FolderScanTracing {
    var begins: [UInt64] = []
    var completions: [UInt64] = []
    var endings: [FolderScanOutcome] = []
    func begin(generation: UInt64, folderURL: URL) { begins.append(generation) }
    func firstBatch(count: Int, generation: UInt64) {}
    func complete(count: Int, generation: UInt64) { completions.append(generation) }
    func end(outcome: FolderScanOutcome, generation: UInt64) { endings.append(outcome) }
}

private func issue140RouteServices(_ base: URL) async throws -> (AccessServices, AccessRootID) {
    let adapter = Issue140Bookmarks()
    let files = try FileAccess(scope: adapter, bookmarks: adapter,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-native")
    let root = try await files.grant(folder: base)
    let services = AccessServices(files: files,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    return (services, root)
}

@MainActor private final class Issue140MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue140Controller(
    services: Task<AccessServices, Error> = Task { throw CancellationError() }
) -> CanvasWindowController {
    _ = NSApplication.shared
    return CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: services,
        motionPolicy: MotionPolicy(source: Issue140MotionSource()))
}

@Test @MainActor func issue140SearchedViewerRejectsOutOfSetFolderSuccessor() throws {
    let controller = issue140Controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), c = ItemID.ephemeral(UUID())
    let folder = URL(fileURLWithPath: "/tmp/issue140-native-search")
    controller.session.beginBrowsing(items: [a, c], sourceVersion: .init(1), scrollAnchor: a)
    controller.session.select(a)
    #expect(CommandRouter().route(.preview, from: .key, to: controller.session))
    #expect(controller.session.previewSet?.currentItemID == a)
    controller.openFolderImage(folder.appendingPathComponent("other-b.png"), rootID: AccessRootID())
    #expect(window.representedURL == nil)
    #expect(controller.session.imageLoader.fileURL == nil)
    controller.session.updateItems([c], sourceVersion: .init(2))
    #expect(controller.session.previewSet?.currentItemID == c)
    #expect(controller.session.previewSet?.itemIDs.contains(b) == false)
}

@Test @MainActor func issue140FrozenPreviewRejectsOutOfSetFolderSuccessorThenEmpties() throws {
    let controller = issue140Controller()
    let window = try #require(controller.window)
    defer { window.close() }
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), c = ItemID.ephemeral(UUID())
    let folder = URL(fileURLWithPath: "/tmp/issue140-native-frozen")
    controller.session.beginBrowsing(items: [a, b, c], sourceVersion: .init(1), scrollAnchor: a)
    controller.session.select(a)
    controller.session.select(c, modifier: .command)
    controller.session.focus(a)
    #expect(CommandRouter().route(.preview, from: .key, to: controller.session))
    #expect(controller.session.previewSet?.itemIDs == [a, c])
    controller.openFolderImage(folder.appendingPathComponent("other-b.png"), rootID: AccessRootID())
    #expect(window.representedURL == nil)
    controller.session.updateItems([c], sourceVersion: .init(2))
    #expect(controller.session.previewSet?.currentItemID == c)
    controller.session.updateItems([], sourceVersion: .init(3))
    #expect(controller.session.previewSet == nil)
    #expect(window.representedURL == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue140BothRootImageOpenRoutesBeginOneCompletedScan() async throws {
    for inputRoute in [false, true] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let image = base.appendingPathComponent("image.png")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        try FileManager.default.copyItem(at: fixture, to: image)
        let (services, root) = try await issue140RouteServices(base)
        let controller = issue140Controller(services: Task { services })
        let window = try #require(controller.window)
        defer { window.close() }
        let trace = Issue140ScanTrace()
        let scan = FolderScanCoordinator(access: services.files, scanner: services.browser,
            trace: trace, watcher: services.watch)
        controller.session.folderScan = scan
        if inputRoute {
            controller.openInputImage(image, accessRequest: .root(root, file: image))
        } else {
            controller.open(image, accessRequest: .root(root, file: image))
        }
        try await waitUntil { !trace.completions.isEmpty }
        #expect(trace.begins == [1])
        #expect(trace.completions == [1])
        #expect(scan.generation == 1)
        #expect(scan.sourceSnapshot?.isComplete == true)
        #expect(scan.sourceSnapshot?.entries.map(\.url.lastPathComponent) == ["image.png"])
        try await waitUntil { controller.session.imageLoader.presented != nil }
        #expect(controller.session.imageLoader.presented != nil)
        #expect(window.representedURL == image)
        #expect(window.attachedSheet == nil)
        scan.end()
    }
}
