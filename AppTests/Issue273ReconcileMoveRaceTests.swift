import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class RaceMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Once armed, moves the file inside the next header request, after the grant was resolved but before
/// the read. This is the order the CI runner hit: reconcile resolved the original path, then the file moved.
/// `armLoader` instead moves it inside the next loader decode request, after its lease resolved the grant.
/// `holdHeader` suspends the next header request until `releaseHeader`, so that reconcile stays in flight.
private final class MoveDuringRequestPipeline: ImagePipeline, @unchecked Sendable {
    let base = ImageIOPipeline()
    private let lock = NSLock()
    private let move: @Sendable () throws -> URL?
    private var armed = false
    private var loaderArmed = false
    private var headers = 0
    private var completedHeaders = 0
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?
    private var movedURL: URL?
    private var ran = 0
    init(move: @escaping @Sendable () throws -> URL?) { self.move = move }
    func arm() { lock.withLock { armed = true } }
    func armLoader() { lock.withLock { loaderArmed = true } }
    var moves: Int { lock.withLock { ran } }
    var moved: URL? { lock.withLock { movedURL } }
    var headerRequests: Int { lock.withLock { headers } }
    var completedHeaderRequests: Int { lock.withLock { completedHeaders } }
    var headerHeld: Bool { lock.withLock { gate != nil } }
    func holdHeader() { lock.withLock { holdNext = true } }
    func releaseHeader() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }?.resume() }
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        let (fire, hold) = lock.withLock { () -> (Bool, Bool) in
            defer { armed = false; holdNext = false; headers += 1 }
            return (armed, holdNext)
        }
        if hold { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        if fire { try moveNow() }
        let request = try await base.request(for: fileURL, maximumPixelSize: maximumPixelSize)
        lock.withLock { completedHeaders += 1 }
        return request
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        let fire = lock.withLock { () -> Bool in
            defer { loaderArmed = false }
            return loaderArmed
        }
        if fire { try moveNow() }
        return try await base.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        try await base.image(for: request)
    }
    private func moveNow() throws {
        let url = try move()
        lock.withLock { ran += 1; movedURL = url }
    }
}

/// The system bookmarks, except that resolution fails once `failResolution` is set.
private final class FailingBookmarks: BookmarkCoding, @unchecked Sendable {
    private let system = SystemSecurityScope()
    private let lock = NSLock()
    private var failing = false
    func failResolution() { lock.withLock { failing = true } }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if lock.withLock({ failing }) { throw CocoaError(.fileNoSuchFile) }
        return try system.resolve(data)
    }
}

@MainActor private func raceController(in base: URL, pipeline: MoveDuringRequestPipeline,
                                       bookmarks: (any BookmarkCoding)? = nil) throws -> CanvasWindowController {
    _ = NSApplication.shared
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: bookmarks ?? scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue273-race")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    return CanvasWindowController(pipeline: pipeline,
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: RaceMotionSource()))
}

private func raceFixture() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
}

/// Opens a File Grant, waits for the viewer to settle, arms the move and starts one reconcile.
@MainActor private func openThenArm(_ file: URL, _ controller: CanvasWindowController,
                                    _ pipeline: MoveDuringRequestPipeline) async throws {
    controller.open(file, accessRequest: .fileGrant(file))
    try await waitUntil { controller.session.imageLoader.phase == .settled }
    #expect(controller.session.imageLoader.phase == .settled)
    pipeline.arm()
    controller.reconcileStandaloneImage()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue273TrashDuringReconcileReadClearsWithoutReconnectSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: raceFixture(), to: file)
    let pipeline = MoveDuringRequestPipeline {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        return trashed as URL?
    }
    defer { if let trashed = pipeline.moved { try? fm.removeItem(at: trashed) } }
    let controller = try raceController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    try await openThenArm(file, controller, pipeline)
    try await waitUntil { (pipeline.moves != 0 && controller.session.imageLoader.fileURL == nil) ||
        window.attachedSheet != nil }
    #expect(pipeline.moves == 1)
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(window.representedURL == nil)
    #expect(window.attachedSheet == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue273DotTrashMoveDuringReconcileReadFollowsWithoutSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ordinaryTrash = base.appendingPathComponent(".Trash")
    try fm.createDirectory(at: ordinaryTrash, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let original = base.appendingPathComponent("image.png")
    let moved = ordinaryTrash.appendingPathComponent("image.png")
    try fm.copyItem(at: raceFixture(), to: original)
    let pipeline = MoveDuringRequestPipeline {
        try FileManager.default.moveItem(at: original, to: moved)
        return moved
    }
    let controller = try raceController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    try await openThenArm(original, controller, pipeline)
    try await waitUntil { (pipeline.moves != 0 &&
        controller.session.imageLoader.presented?.fileURL.standardizedFileURL == moved.standardizedFileURL) ||
        window.attachedSheet != nil }
    #expect(pipeline.moves == 1)
    #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == moved.standardizedFileURL)
    #expect(window.representedURL?.standardizedFileURL == moved.standardizedFileURL)
    #expect(window.attachedSheet == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue257RenameDuringHeldReconcileReadFollowsWithoutSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let original = base.appendingPathComponent("image.png")
    let renamed = base.appendingPathComponent("renamed.png")
    try fm.copyItem(at: raceFixture(), to: original)
    let pipeline = MoveDuringRequestPipeline { nil }
    let controller = try raceController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    controller.open(original, accessRequest: .fileGrant(original))
    try await waitUntil {
        controller.session.imageLoader.phase == .settled && pipeline.completedHeaderRequests != 0
    }
    #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == original.standardizedFileURL)
    pipeline.holdHeader()
    defer { pipeline.releaseHeader() }
    controller.reconcileStandaloneImage()
    try await waitUntil { pipeline.headerHeld }
    #expect(pipeline.headerHeld)
    try fm.moveItem(at: original, to: renamed)
    pipeline.releaseHeader()
    try await waitUntil {
        (controller.session.imageLoader.fileURL?.standardizedFileURL == renamed.standardizedFileURL &&
         controller.session.imageLoader.presented?.fileURL.standardizedFileURL == renamed.standardizedFileURL &&
         window.representedURL?.standardizedFileURL == renamed.standardizedFileURL) || window.attachedSheet != nil
    }
    #expect(window.attachedSheet == nil, "sheet: \(sheetText(window))")
    #expect(controller.session.imageLoader.fileURL?.standardizedFileURL == renamed.standardizedFileURL)
    #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == renamed.standardizedFileURL)
    #expect(window.representedURL?.standardizedFileURL == renamed.standardizedFileURL)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue273TrashDuringLoaderDetailRequestClearsWithoutReconnectSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: raceFixture().deletingLastPathComponent().appendingPathComponent("pan-grid-4096x3072.png"),
                    to: file)
    let pipeline = MoveDuringRequestPipeline {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        return trashed as URL?
    }
    defer { if let trashed = pipeline.moved { try? fm.removeItem(at: trashed) } }
    let controller = try raceController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    controller.open(file, accessRequest: .fileGrant(file))
    // Settle the viewer and the reconcile that open starts, so the grant is watched before the trash.
    try await waitUntil { controller.session.imageLoader.phase == .settled && pipeline.headerRequests != 0 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.session.imageLoader.phase == .settled)
    #expect(controller.session.imageLoader.presented != nil)
    // A reconcile already in flight: the Trash's vnode event only marks another one pending,
    // so the loader's failure is the first to report the trashed file.
    pipeline.holdHeader()
    defer { pipeline.releaseHeader() }
    controller.reconcileStandaloneImage()
    try await waitUntil { pipeline.headerHeld }
    #expect(pipeline.headerHeld)
    // A larger detail request: the image stays shown while the loader refines and finds the file trashed.
    pipeline.armLoader()
    controller.session.requireImageResolution(4096)
    #expect(controller.session.imageLoader.phase == .refining)
    try await waitUntil { (pipeline.moves != 0 && (controller.session.imageLoader.phase == .failed ||
        controller.session.imageLoader.fileURL == nil)) || window.attachedSheet != nil }
    #expect(window.attachedSheet == nil, "sheet: \(sheetText(window))")
    pipeline.releaseHeader()
    try await waitUntil { controller.session.imageLoader.fileURL == nil || window.attachedSheet != nil }
    #expect(pipeline.moves == 1)
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(window.representedURL == nil)
    #expect(window.attachedSheet == nil, "sheet: \(sheetText(window))")
}

/// A read that fails for a real access loss still asks to reconnect.
@MainActor private func expectReconnectSheet(_ window: NSWindow, _ pipeline: MoveDuringRequestPipeline) async throws {
    try await waitUntil { window.attachedSheet != nil }
    #expect(pipeline.moves == 1)
    #expect(window.attachedSheet is NSPanel, "sheet: \(sheetText(window))")
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue273RemovalDuringReconcileReadStillShowsReconnectSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: raceFixture(), to: file)
    let pipeline = MoveDuringRequestPipeline {
        try FileManager.default.removeItem(at: file)
        return nil
    }
    let controller = try raceController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    try await openThenArm(file, controller, pipeline)
    try await expectReconnectSheet(window, pipeline)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue273FailedReresolutionDuringReconcileReadStillShowsReconnectSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let original = base.appendingPathComponent("image.png")
    let moved = base.appendingPathComponent("moved.png")
    try fm.copyItem(at: raceFixture(), to: original)
    let bookmarks = FailingBookmarks()
    // The file moves, but its bookmark no longer resolves, so re-resolution throws needsFileReconnection.
    let pipeline = MoveDuringRequestPipeline {
        try FileManager.default.moveItem(at: original, to: moved)
        bookmarks.failResolution()
        return moved
    }
    let controller = try raceController(in: base, pipeline: pipeline, bookmarks: bookmarks)
    let window = try #require(controller.window)
    defer { window.close() }
    try await openThenArm(original, controller, pipeline)
    try await expectReconnectSheet(window, pipeline)
}
