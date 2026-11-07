import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private func r2Wait(
    fileID: String = #fileID, line: Int = #line, _ condition: @MainActor () async -> Bool
) async throws {
    try await waitUntil(fileID: fileID, line: line) { await condition() }
}

@MainActor private final class ReaderMotion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private final class ReaderPipeline: ImagePipeline, @unchecked Sendable {
    let base = ImageIOPipeline()
    private let lock = NSLock()
    private var holdHeader = false
    private var headerGate: CheckedContinuation<Void, Never>?
    private var admissionURL: URL?
    private var admissionGate: CheckedContinuation<Void, Never>?
    private var completed = 0
    private var headerCount = 0
    private var identityCount = 0
    private var decodeCount = 0
    var heldHeader: Bool { lock.withLock { headerGate != nil } }
    var heldAdmission: Bool { lock.withLock { admissionGate != nil } }
    var completedHeaders: Int { lock.withLock { completed } }
    var counts: [Int] { lock.withLock { [headerCount, identityCount, decodeCount] } }
    func armHeader() { lock.withLock { holdHeader = true } }
    func armAdmission(_ url: URL) { lock.withLock { admissionURL = url } }
    func releaseHeader() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { headerGate = nil }; return headerGate }?.resume() }
    func releaseAdmission() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { admissionGate = nil }; return admissionGate }?.resume() }
    func request(for url: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        let hold = lock.withLock { () -> Bool in defer { holdHeader = false; headerCount += 1 }; return holdHeader }
        defer { lock.withLock { completed += 1 } }
        if hold { await withCheckedContinuation { continuation in lock.withLock { headerGate = continuation } } }
        return try await base.request(for: url, maximumPixelSize: maximumPixelSize)
    }
    func request(for url: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        let hold = lock.withLock { () -> Bool in
            identityCount += 1
            guard admissionURL == url else { return false }
            admissionURL = nil
            return true
        }
        if hold { await withCheckedContinuation { continuation in lock.withLock { admissionGate = continuation } } }
        return try await base.request(for: url, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        lock.withLock { decodeCount += 1 }
        return try await base.image(for: request)
    }
}

private final class ReaderScope: SecurityScope, @unchecked Sendable {
    let real = SystemSecurityScope()
    private let lock = NSLock()
    private var history: [URL] = []
    var urls: [URL] { lock.withLock { history } }
    func start(_ url: URL) -> Bool { lock.withLock { history.append(url) }; return real.start(url) }
    func stop(_ url: URL) { real.stop(url) }
    func isReadable(_ url: URL) -> Bool { real.isReadable(url) }
}

private actor ReaderMetadata: InspectorMetadataReading {
    let base: WindowInspectorReader
    private var heldURL: URL?
    private var failURL: URL?
    private var gate: CheckedContinuation<Void, Never>?
    private var completions = 0
    init(_ base: WindowInspectorReader) { self.base = base }
    func armHeldFailure(_ url: URL) { heldURL = url }
    func armFailure(_ url: URL) { failURL = url }
    var held: Bool { gate != nil }
    var completed: Int { completions }
    func release() { gate?.resume(); gate = nil }
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        if heldURL == url {
            heldURL = nil
            await withCheckedContinuation { gate = $0 }
            completions += 1
            throw InspectorReadError.unreadable
        }
        if failURL == url { failURL = nil; completions += 1; throw InspectorReadError.unreadable }
        return try await base.read(url, access: access)
    }
}

@MainActor private final class ReaderRig {
    let base: URL
    let a: URL
    let b: URL
    let pipeline = ReaderPipeline()
    let scope = ReaderScope()
    let services: Task<AccessServices, Error>
    init() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        a = base.appendingPathComponent("reader-a.png")
        b = base.appendingPathComponent("reader-b.png")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic")
        try fm.copyItem(at: fixtures.appendingPathComponent("pan-grid-4096x3072.png"), to: a)
        try fm.copyItem(at: fixtures.appendingPathComponent("portrait-2x3.png"), to: b)
        let access = try FileAccess(scope: scope, bookmarks: scope.real,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue233-r2")
        let value = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        services = Task { value }
    }
    var realReader: WindowInspectorReader { WindowInspectorReader(services: services, pipeline: pipeline) }
    func controller(reader: (any InspectorMetadataReading)? = nil) -> CanvasWindowController {
        CanvasWindowController(pipeline: pipeline, preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: services,
            motionPolicy: MotionPolicy(source: ReaderMotion()), inspectorReader: reader)
    }
    func clean(_ window: NSWindow) {
        pipeline.releaseHeader(); pipeline.releaseAdmission()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path)
        window.close()
        try? FileManager.default.removeItem(at: base)
    }
    func denyA() throws { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: a.path) }
    func restoreA() throws { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path) }
    func assertScopesAreFiles() {
        let allowed = [a, b].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        #expect(scope.urls.allSatisfy { allowed.contains($0.standardizedFileURL.resolvingSymlinksInPath()) })
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("roots.json").path))
    }
}

@MainActor private func readerClear(_ controller: CanvasWindowController, _ window: NSWindow) {
    #expect(!controller.hasImage)
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(controller.session.imageLoader.presented == nil)
    #expect(window.title == "Mado")
    #expect(window.representedURL == nil)
    #expect(controller.inspector.name == nil)
    #expect(controller.inspector.value == .unknown)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    if let content = window.contentView {
        let values = descendants(content).flatMap { [$0.accessibilityLabel(), $0.accessibilityValue() as? String] }.compactMap { $0 }
        #expect(!values.contains { $0.contains("reader-a.png") })
    }
}

@MainActor private func readerSheetObserver(_ controller: CanvasWindowController, _ window: NSWindow) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { _ in
        MainActor.assumeIsolated { readerClear(controller, window) }
    }
}

@MainActor private func readerSettle(_ rig: ReaderRig, _ controller: CanvasWindowController) async throws {
    controller.open(rig.a, accessRequest: .fileGrant(rig.a))
    try await r2Wait { controller.session.imageLoader.phase == .settled && rig.pipeline.completedHeaders > 0 }
    #expect(controller.hasImage)
    #expect(controller.route(.inspector, from: .key))
    try await r2Wait { if case .known = controller.inspector.value { true } else { false } }
    if case .known = controller.inspector.value {} else { Issue.record("Inspector must populate before reader loss") }
}

@MainActor private func readerHoldReconcile(_ rig: ReaderRig, _ controller: CanvasWindowController) async throws {
    rig.pipeline.armHeader()
    controller.reconcileStandaloneImage()
    try await r2Wait { rig.pipeline.heldHeader }
    #expect(rig.pipeline.heldHeader)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233R2InspectorOnlyPOSIXLossClearsBeforeSheet() async throws {
    let rig = try ReaderRig()
    let viewer = rig.controller()
    let window = try #require(viewer.window)
    defer { rig.clean(window) }
    try await readerSettle(rig, viewer)
    try await readerHoldReconcile(rig, viewer)
    let observer = readerSheetObserver(viewer, window)
    defer { NotificationCenter.default.removeObserver(observer) }
    try rig.denyA()
    #expect(FileManager.default.fileExists(atPath: rig.a.path))
    #expect(viewer.hasImage)
    #expect(window.attachedSheet == nil)
    viewer.inspector.select(itemID: nil, url: rig.a, access: .fileGrant(rig.a), refresh: true)
    try await r2Wait { window.attachedSheet != nil }
    #expect(window.attachedSheet != nil)
    readerClear(viewer, window)
    rig.assertScopesAreFiles()
    let completed = rig.pipeline.completedHeaders
    rig.pipeline.releaseHeader()
    try await r2Wait { rig.pipeline.completedHeaders > completed }
    readerClear(viewer, window)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233R2LoaderExistingFilePOSIXLossClearsWhileReconcileHeld() async throws {
    let rig = try ReaderRig()
    let viewer = rig.controller()
    let window = try #require(viewer.window)
    defer { rig.clean(window) }
    try await readerSettle(rig, viewer)
    try await readerHoldReconcile(rig, viewer)
    let observer = readerSheetObserver(viewer, window)
    defer { NotificationCenter.default.removeObserver(observer) }
    try rig.denyA()
    #expect(FileManager.default.fileExists(atPath: rig.a.path))
    viewer.session.requireImageResolution(4096)
    try await r2Wait { window.attachedSheet != nil }
    #expect(window.attachedSheet != nil)
    readerClear(viewer, window)
    let completed = rig.pipeline.completedHeaders
    rig.pipeline.releaseHeader()
    try await r2Wait { rig.pipeline.completedHeaders > completed }
    readerClear(viewer, window)
    rig.assertScopesAreFiles()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233R2StaleMetadataAndProbeNeverClearNewInput() async throws {
    let rig = try ReaderRig()
    let metadata = ReaderMetadata(rig.realReader)
    let viewer = rig.controller(reader: metadata)
    let window = try #require(viewer.window)
    defer { rig.clean(window) }
    try await readerSettle(rig, viewer)
    await metadata.armHeldFailure(rig.a)
    viewer.inspector.select(itemID: nil, url: rig.a, access: .fileGrant(rig.a), refresh: true)
    try await r2Wait { await metadata.held }
    viewer.openInput([rig.b])
    try await r2Wait { viewer.session.imageLoader.phase == .settled && window.representedURL == rig.b }
    let b = try #require(viewer.session.imageLoader.presented)
    await metadata.release()
    try await r2Wait { await metadata.completed > 0 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(viewer.session.imageLoader.presented?.key == b.key)
    #expect(window.title == "reader-b.png")
    #expect(viewer.inspector.name == "reader-b.png")
    #expect(window.attachedSheet == nil)

    viewer.open(rig.a, accessRequest: .fileGrant(rig.a))
    try await r2Wait { viewer.session.imageLoader.phase == .settled && window.representedURL == rig.a }
    try await r2Wait { if case .known = viewer.inspector.value { true } else { false } }
    await metadata.armHeldFailure(rig.a)
    viewer.inspector.select(itemID: nil, url: rig.a, access: .fileGrant(rig.a), refresh: true)
    try await r2Wait { await metadata.held }
    #expect(await metadata.held)
    try await readerHoldReconcile(rig, viewer)
    let a = try #require(viewer.session.imageLoader.presented)
    let generation = viewer.session.imageLoader.generation
    try rig.denyA()
    // Capture A's authority synchronously; the real probe Task cannot execute until this actor yields.
    let probe = viewer.reportFileGrantReadFailure(rig.a)
    rig.pipeline.armAdmission(rig.b)
    viewer.openInput([rig.b])
    try await r2Wait { rig.pipeline.heldAdmission }
    #expect(rig.pipeline.heldAdmission)
    await probe.value
    let priorMetadataCompletions = await metadata.completed
    await metadata.release()
    try await r2Wait { await metadata.completed > priorMetadataCompletions }
    try await r2Wait { viewer.inspector.value == .unreadable || window.attachedSheet != nil }
    // The old selection is still current, but its presentation input stamp predates B.
    await viewer.reportFileGrantReadFailure(rig.a).value
    #expect(viewer.session.imageLoader.generation == generation)
    #expect(viewer.session.imageLoader.presented?.key == a.key)
    #expect(viewer.hasImage)
    #expect(window.attachedSheet == nil)
    let priorHeaderCompletions = rig.pipeline.completedHeaders
    rig.pipeline.releaseHeader()
    try await r2Wait { rig.pipeline.completedHeaders > priorHeaderCompletions }
    #expect(rig.pipeline.completedHeaders > priorHeaderCompletions)
    // The I/O gate has completed; allow its actor release/catch to deliver while B is still held.
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.pipeline.heldAdmission)
    #expect(viewer.session.imageLoader.generation == generation)
    #expect(viewer.session.imageLoader.presented?.key == a.key)
    #expect(window.attachedSheet == nil)
    rig.pipeline.releaseAdmission()
    try await r2Wait { viewer.session.imageLoader.phase == .settled && window.representedURL == rig.b }
    #expect(viewer.session.imageLoader.presented?.fileURL == rig.b)
    #expect(window.title == "reader-b.png")
    #expect(viewer.inspector.name == "reader-b.png")
    rig.pipeline.releaseHeader()
    try rig.restoreA()
    await viewer.reportFileGrantReadFailure(rig.a).value
    #expect(viewer.session.imageLoader.presented?.fileURL == rig.b)
    #expect(window.attachedSheet == nil)
    rig.assertScopesAreFiles()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233R2ReadableMetadataAndCorruptDecodeErrorsNeverReconnectOrLoop() async throws {
    let rig = try ReaderRig()
    let metadata = ReaderMetadata(rig.realReader)
    let viewer = rig.controller(reader: metadata)
    let window = try #require(viewer.window)
    defer { rig.clean(window) }
    try await readerSettle(rig, viewer)
    try await readerHoldReconcile(rig, viewer)
    await metadata.armFailure(rig.a)
    viewer.inspector.select(itemID: nil, url: rig.a, access: .fileGrant(rig.a), refresh: true)
    try await r2Wait { viewer.inspector.value == .unreadable }
    await viewer.reportFileGrantReadFailure(rig.a).value
    #expect(viewer.hasImage)
    #expect(viewer.inspector.value == .unreadable)
    #expect(window.attachedSheet == nil)
    let before = rig.pipeline.counts
    try await Task.sleep(for: .milliseconds(150))
    #expect(rig.pipeline.counts == before)
    // Keep the original inode so its File Grant stays the same; only ImageIO readability changes.
    try Data("This is readable, deliberately corrupt PNG input.".utf8).write(to: rig.a)
    let handle = try FileHandle(forReadingFrom: rig.a)
    #expect(try handle.read(upToCount: 1)?.isEmpty == false)
    try handle.close()
    viewer.session.requireImageResolution(4096)
    try await r2Wait { viewer.session.imageLoader.phase == .failed }
    #expect(viewer.session.imageLoader.phase == .failed)
    await viewer.reportFileGrantReadFailure(rig.a).value
    let after = rig.pipeline.counts
    #expect(window.attachedSheet == nil)
    try await Task.sleep(for: .milliseconds(150))
    #expect(rig.pipeline.counts == after)
    #expect(viewer.session.imageLoader.phase == .failed)
    #expect(window.attachedSheet == nil)
    rig.assertScopesAreFiles()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233R2FreshReaderAfterRejectedInputStillDetectsLoss() async throws {
    for loader in [false, true] {
        let rig = try ReaderRig()
        let metadata = ReaderMetadata(rig.realReader)
        let viewer = rig.controller(reader: metadata)
        let window = try #require(viewer.window)
        defer { rig.clean(window) }
        try await readerSettle(rig, viewer)
        if !loader {
            // Inspector visibility changes must not accidentally start another loader read in this episode.
            viewer.session.requireImageResolution(4096)
            try await r2Wait { viewer.session.imageLoader.phase == .settled }
            #expect(viewer.session.imageLoader.phase == .settled)
        }
        await metadata.armHeldFailure(rig.a)
        viewer.inspector.select(itemID: nil, url: rig.a, access: .fileGrant(rig.a), refresh: true)
        try await r2Wait { await metadata.held }
        #expect(await metadata.held)
        try await readerHoldReconcile(rig, viewer)
        let a = try #require(viewer.session.imageLoader.presented)
        let generation = viewer.session.imageLoader.generation
        let unsupported = rig.base.appendingPathComponent("unsupported.zip")
        try Data([0x50, 0x4b]).write(to: unsupported)
        viewer.openInput([unsupported])
        try await r2Wait { window.attachedSheet != nil }
        let rejected = try #require(window.attachedSheet)
        #expect(viewer.session.imageLoader.presented?.key == a.key)
        #expect(viewer.session.imageLoader.generation == generation)
        window.endSheet(rejected, returnCode: .alertFirstButtonReturn)
        try await r2Wait { window.attachedSheet == nil }
        try rig.denyA()
        let completed = await metadata.completed
        await metadata.release()
        try await r2Wait { await metadata.completed > completed }
        try await r2Wait { viewer.inspector.value != .loading }
        await viewer.reportFileGrantReadFailure(rig.a).value
        #expect(viewer.session.imageLoader.presented?.key == a.key)
        #expect(viewer.session.imageLoader.generation == generation)
        #expect(window.attachedSheet == nil)
        let observer = readerSheetObserver(viewer, window)
        defer { NotificationCenter.default.removeObserver(observer) }
        if loader {
            #expect(viewer.route(.inspector, from: .key))
            #expect(!viewer.inspectorVisible)
            func canvas(in view: NSView) -> CanvasInputBridge? {
                if let canvas = view as? CanvasInputBridge { return canvas }
                return view.subviews.lazy.compactMap { canvas(in: $0) }.first
            }
            let surface = try #require(window.contentView.flatMap { canvas(in: $0) })
            #expect(surface.apply(.actualPixels, from: .key) != nil)
        } else {
            #expect(viewer.route(.inspector, from: .key))
            #expect(!viewer.inspectorVisible)
            #expect(viewer.route(.inspector, from: .key))
            #expect(viewer.inspectorVisible)
        }
        try await r2Wait { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
        readerClear(viewer, window)
        #expect(FileManager.default.fileExists(atPath: rig.a.path))
        #expect(rig.pipeline.heldHeader)
        rig.assertScopesAreFiles()
    }
}

/// Performs only a real move after returning the original resource identity to the lease resolver.
/// Thus acquire returns its old URL and the following actual FileHandle open sees ENOENT.
private final class ReaderMoveAfterIdentity: FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var destination: URL?
    private var moves = 0
    let original: URL
    let move: @Sendable () throws -> URL
    init(original: URL, move: @escaping @Sendable () throws -> URL) { self.original = original; self.move = move }
    func arm() { lock.withLock { armed = true } }
    var moved: URL? { lock.withLock { destination } }
    var count: Int { lock.withLock { moves } }
    func identity(for file: URL) throws -> FileResourceIdentity? {
        let result = try URLIdentityResourceReader().identity(for: file)
        let fire = lock.withLock { () -> Bool in
            guard armed, file == original else { return false }
            armed = false
            return true
        }
        if fire { let target = try move(); lock.withLock { destination = target; moves += 1 } }
        return result
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233R2ProbeMissingLeasePathPreservesRenameAndTrashRecovery() async throws {
    for kind in ["rename", "ordinaryTrash", "systemTrash"] {
        let rig = try ReaderRig()
        let ordinary = rig.base.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        let target = kind == "ordinaryTrash" ? ordinary.appendingPathComponent("reader-a.png") : rig.base.appendingPathComponent("renamed.png")
        let file = rig.a
        let moving = ReaderMoveAfterIdentity(original: file) {
            if kind == "systemTrash" {
                var result: NSURL?
                try FileManager.default.trashItem(at: file, resultingItemURL: &result)
                return try #require(result as URL?)
            }
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }
        let access = try FileAccess(scope: rig.scope, bookmarks: rig.scope.real,
            store: BookmarkStore(url: rig.base.appendingPathComponent("moved-roots.json")), buildSHA: "issue233-r2-move", resourceReader: moving)
        let value = AccessServices(files: access,
            recent: RecentFolderStore(url: rig.base.appendingPathComponent("moved-recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        let viewer = CanvasWindowController(pipeline: rig.pipeline, preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { value }, motionPolicy: MotionPolicy(source: ReaderMotion()))
        let window = try #require(viewer.window)
        defer {
            rig.clean(window)
            if kind == "systemTrash", let moved = moving.moved { try? FileManager.default.removeItem(at: moved) }
        }
        try await readerSettle(rig, viewer)
        try await readerHoldReconcile(rig, viewer)
        moving.arm()
        await viewer.reportFileGrantReadFailure(file).value
        #expect(moving.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(window.attachedSheet == nil)
        rig.pipeline.releaseHeader()
        if kind == "systemTrash" {
            try await r2Wait { viewer.session.imageLoader.fileURL == nil || window.attachedSheet != nil }
            #expect(!viewer.hasImage)
            #expect(viewer.session.imageLoader.fileURL == nil)
            #expect(window.representedURL == nil)
            #expect(window.title == "Mado")
        } else {
            let moved = try #require(moving.moved)
            try await r2Wait {
                viewer.session.imageLoader.presented?.fileURL.standardizedFileURL.resolvingSymlinksInPath()
                    == moved.standardizedFileURL.resolvingSymlinksInPath() || window.attachedSheet != nil
            }
            #expect(viewer.session.imageLoader.presented?.fileURL.standardizedFileURL.resolvingSymlinksInPath()
                == moved.standardizedFileURL.resolvingSymlinksInPath())
            #expect(window.representedURL?.standardizedFileURL.resolvingSymlinksInPath()
                == moved.standardizedFileURL.resolvingSymlinksInPath())
            #expect(window.title == moved.lastPathComponent)
        }
        #expect(window.attachedSheet == nil)
        // Resolve the existing parent, so a no-longer-existing original leaf retains its canonical alias.
        func canonicalFile(_ url: URL) -> URL {
            url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        }
        let allowed = [file, rig.b, moving.moved].compactMap { $0 }.map(canonicalFile)
        #expect(rig.scope.urls.allSatisfy { allowed.contains(canonicalFile($0)) })
        #expect(!FileManager.default.fileExists(atPath: rig.base.appendingPathComponent("moved-roots.json").path))
    }
}
