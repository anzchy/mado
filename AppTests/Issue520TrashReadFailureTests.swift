import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue520Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Counts completion of the initial reconciliation read, so setup proves the standalone
/// grant has been installed. The pipeline and all access/bookmark decisions remain real.
private final class Issue520Pipeline: ImagePipeline, @unchecked Sendable {
    private let base = ImageIOPipeline()
    private let lock = NSLock()
    private var completed = 0
    var completedHeaders: Int { lock.withLock { completed } }
    func request(for url: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        let result = try await base.request(for: url, maximumPixelSize: maximumPixelSize)
        lock.withLock { completed += 1 }
        return result
    }
    func request(for url: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await base.request(for: url, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        try await base.image(for: request)
    }
}

@MainActor private final class Issue520Fixture {
    let base: URL
    let file: URL
    let controller: CanvasWindowController
    let pipeline = Issue520Pipeline()
    var trashed: NSURL?
    var window: NSWindow { controller.window! }

    init() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = base.appendingPathComponent("issue520.png")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        try fm.copyItem(at: source, to: file)
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue520")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        controller = CanvasWindowController(pipeline: pipeline,
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: Issue520Motion()))
    }
    func open() async throws {
        controller.open(file, accessRequest: .fileGrant(file))
        try await waitUntil { self.controller.session.imageLoader.phase == .settled && self.pipeline.completedHeaders > 0 }
        try #require(controller.session.imageLoader.presented != nil)
        try #require(window.attachedSheet == nil)
    }
    // Keep the existing failure/report sequence in one fixture completion boundary.
    // A later loader callback can replace the report that this boundary is awaiting.
    func reconnectAfterDeniedFailure(overlappingCallback: Bool = false) async throws {
        controller.imageLoadFailed(CocoaError(.fileReadNoPermission))
        let observed = controller.reportFileGrantReadFailure(file)
        if overlappingCallback {
            controller.imageLoadFailed(CocoaError(.fileReadNoPermission))
            try #require(observed.isCancelled)
        }
        await observed.value
        try await waitUntil { self.window.attachedSheet != nil }
    }
    func trash() throws { try FileManager.default.trashItem(at: file, resultingItemURL: &trashed) }
    func clearAssertions() {
        #expect(controller.session.imageLoader.fileURL == nil)
        #expect(controller.session.imageLoader.presented == nil)
        #expect(window.representedURL == nil)
    }
    func clean() {
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
        window.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let trashed { try? FileManager.default.removeItem(at: trashed as URL) }
        try? FileManager.default.removeItem(at: base)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue520TrashBeforeGenericLoadFailureDoesNotReconnect() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    // No suspension between Trash and the real loader callback: vnode/explicit reconcile
    // cannot win this order. The old missing-path shortcut attaches a sheet right here.
    try f.trash()
    f.controller.imageLoadFailed(CocoaError(.fileReadNoSuchFile))
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
    // Complete the shared production probe explicitly, independent of watcher scheduling.
    await f.controller.reportFileGrantReadFailure(f.file).value
    f.clearAssertions()
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue520UnlinkedFileGenericLoadFailureStillReconnects() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    try FileManager.default.removeItem(at: f.file)
    f.controller.imageLoadFailed(CocoaError(.fileReadNoSuchFile))
    await f.controller.reportFileGrantReadFailure(f.file).value
    f.clearAssertions()
    #expect(f.window.attachedSheet != nil)
    #expect(sheetText(f.window).contains(String(localized: "Choose this image again to reconnect access.")))
}

// Unchanged-branch control: chmod 000 leaves the display path present.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue520DeniedFileGenericLoadFailureStillReconnects() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.file.path)
    #expect(throws: (any Error).self) { try FileHandle(forReadingFrom: f.file).close() }
    try await f.reconnectAfterDeniedFailure()
    f.clearAssertions()
    #expect(f.window.attachedSheet != nil)
    #expect(sheetText(f.window).contains(String(localized: "Choose this image again to reconnect access.")))
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue520TrashClearedBeforeLateGenericFailureStaysEmpty() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    try f.trash()
    f.controller.reconcileStandaloneImage()
    try await waitUntil { f.controller.session.imageLoader.fileURL == nil }
    f.clearAssertions()
    f.controller.imageLoadFailed(CocoaError(.fileReadNoSuchFile))
    await f.controller.reportFileGrantReadFailure(f.file).value
    f.clearAssertions()
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue520ReadableGenericLoadFailureDoesNotReconnect() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    let handle = try FileHandle(forReadingFrom: f.file)
    try handle.close()
    f.controller.imageLoadFailed(CocoaError(.fileReadCorruptFile))
    await f.controller.reportFileGrantReadFailure(f.file).value
    #expect(f.controller.session.imageLoader.fileURL == f.file)
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
}

// These controls never start a replacement probe: imageLoadFailed owns the async work.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue520CallbackProbeTrashClearsWithoutSheet() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    try f.trash()
    f.controller.imageLoadFailed(CocoaError(.fileReadNoSuchFile))
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
    try await waitUntil {
        f.controller.session.imageLoader.fileURL == nil || f.window.attachedSheet != nil
    }
    f.clearAssertions()
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue520CallbackProbeUnlinkedFileReconnects() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    try FileManager.default.removeItem(at: f.file)
    f.controller.imageLoadFailed(CocoaError(.fileReadNoSuchFile))
    try await waitUntil { f.window.attachedSheet != nil }
    f.clearAssertions()
    #expect(f.window.attachedSheet != nil)
    #expect(sheetText(f.window).contains(String(localized: "Choose this image again to reconnect access.")))
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue520CallbackProbeMovedFileFollowsNewLocation() async throws {
    let f = try Issue520Fixture()
    defer { f.clean() }
    try await f.open()
    let moved = f.base.appendingPathComponent("moved.png")
    try FileManager.default.moveItem(at: f.file, to: moved)
    f.controller.imageLoadFailed(CocoaError(.fileReadNoSuchFile))
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
    try await waitUntil {
        (f.controller.session.imageLoader.presented?.fileURL.standardizedFileURL == moved.standardizedFileURL
            && f.window.representedURL?.standardizedFileURL == moved.standardizedFileURL)
            || f.window.attachedSheet != nil
    }
    #expect(f.controller.session.imageLoader.fileURL?.standardizedFileURL == moved.standardizedFileURL)
    #expect(f.controller.session.imageLoader.presented?.fileURL.standardizedFileURL == moved.standardizedFileURL)
    #expect(f.window.representedURL?.standardizedFileURL == moved.standardizedFileURL)
    #expect(f.window.attachedSheet == nil, "sheet: \(sheetText(f.window))")
}

// Control the callback replacement order without changing any filesystem outcome.
// The fixture must return only when the recovery observed by its caller is ready.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue630DeniedFixtureWaitsForOverlappingFailureRecovery() async throws {
    for _ in 0..<20 {
        let f = try Issue520Fixture()
        defer { f.clean() }
        try await f.open()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.file.path)
        #expect(throws: (any Error).self) { try FileHandle(forReadingFrom: f.file).close() }
        try await f.reconnectAfterDeniedFailure(overlappingCallback: true)
        f.clearAssertions()
        #expect(f.window.attachedSheet != nil)
        #expect(sheetText(f.window).contains(String(localized: "Choose this image again to reconnect access.")))
        // Drain the actual recovery even when the fixture returned too early, so the
        // following iteration cannot cancel the operation that demonstrates the race.
        try await waitUntil { f.window.attachedSheet != nil }
    }
}
