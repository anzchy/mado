import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private func lossWait(
    fileID: String = #fileID, line: Int = #line, _ condition: @MainActor () -> Bool
) async throws {
    try await waitUntil(fileID: fileID, line: line) { condition() }
}

@MainActor private final class LossMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Once armed, moves the file inside the next header request, after the grant was resolved but before
/// the read. This is the order the CI runner hit: reconcile resolved the original path, then the file moved.
/// `armLoader` instead moves it inside the next loader decode request, after its lease resolved the grant.
/// `holdHeader` suspends the next header request until `releaseHeader`, so that reconcile stays in flight.
private final class LossPipeline: ImagePipeline, @unchecked Sendable {
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
        defer { lock.withLock { completedHeaders += 1 } }
        return try await base.request(for: fileURL, maximumPixelSize: maximumPixelSize)
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

@MainActor private func lossController(in base: URL, pipeline: LossPipeline,
                                       bookmarks: (any BookmarkCoding)? = nil, scope suppliedScope: (any SecurityScope)? = nil) throws -> CanvasWindowController {
    _ = NSApplication.shared
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: suppliedScope ?? scope, bookmarks: bookmarks ?? scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue273-race")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    return CanvasWindowController(pipeline: pipeline,
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: LossMotionSource()))
}

private func lossFixture() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
}

/// Opens a File Grant, waits for the viewer to settle, arms the move and starts one reconcile.
@MainActor private func lossOpenThenArm(_ file: URL, _ controller: CanvasWindowController,
                                    _ pipeline: LossPipeline) async throws {
    controller.open(file, accessRequest: .fileGrant(file))
    try await lossWait { controller.session.imageLoader.phase == .settled }
    #expect(controller.session.imageLoader.phase == .settled)
    pipeline.arm()
    controller.reconcileStandaloneImage()
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233HeldRenameDuringHeldReconcileReadFollowsWithoutSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let original = base.appendingPathComponent("image.png")
    let renamed = base.appendingPathComponent("renamed.png")
    try fm.copyItem(at: lossFixture(), to: original)
    let pipeline = LossPipeline { nil }
    let controller = try lossController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    controller.open(original, accessRequest: .fileGrant(original))
    try await lossWait {
        controller.session.imageLoader.phase == .settled && pipeline.completedHeaderRequests != 0
    }
    #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == original.standardizedFileURL)
    pipeline.holdHeader()
    defer { pipeline.releaseHeader() }
    controller.reconcileStandaloneImage()
    try await lossWait { pipeline.headerHeld }
    #expect(pipeline.headerHeld)
    try fm.moveItem(at: original, to: renamed)
    pipeline.releaseHeader()
    try await lossWait {
        (controller.session.imageLoader.fileURL?.standardizedFileURL == renamed.standardizedFileURL &&
         controller.session.imageLoader.presented?.fileURL.standardizedFileURL == renamed.standardizedFileURL &&
         window.representedURL?.standardizedFileURL == renamed.standardizedFileURL) || window.attachedSheet != nil
    }
    #expect(window.attachedSheet == nil, "sheet: \(sheetText(window))")
    #expect(controller.session.imageLoader.fileURL?.standardizedFileURL == renamed.standardizedFileURL)
    #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == renamed.standardizedFileURL)
    #expect(window.representedURL?.standardizedFileURL == renamed.standardizedFileURL)
}


@MainActor private func lossAssertCleared(_ controller: CanvasWindowController, _ window: NSWindow) {
    #expect(!controller.hasImage)
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(controller.session.imageLoader.presented == nil)
    #expect(window.title == "Picsee")
    #expect(window.representedURL == nil)
    #expect(controller.inspector.name == nil)
    #expect(controller.inspector.value == .unknown)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    if let content = window.contentView {
        let strings = descendants(content).flatMap { [$0.accessibilityLabel(), $0.accessibilityValue() as? String] }.compactMap { $0 }
        #expect(!strings.contains { $0.contains("image.png") })
    }
}

@MainActor private func lossObserveBeforeSheet(_ controller: CanvasWindowController, _ window: NSWindow) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { _ in
        MainActor.assumeIsolated { lossAssertCleared(controller, window) }
    }
}

@MainActor private func lossSettle(_ controller: CanvasWindowController, _ file: URL, _ pipeline: LossPipeline) async throws {
    controller.open(file, accessRequest: .fileGrant(file))
    try await lossWait { controller.session.imageLoader.phase == .settled && pipeline.completedHeaderRequests > 0 }
    #expect(controller.session.imageLoader.phase == .settled)
    #expect(controller.route(.inspector, from: .key))
    try await lossWait { if case .known = controller.inspector.value { true } else { false } }
    #expect(controller.inspector.name == file.lastPathComponent)
    if case .known = controller.inspector.value {} else { Issue.record("Inspector must populate before loss") }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233DecodeFirstLossClearsAndRejectsLateWork() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: lossFixture().deletingLastPathComponent().appendingPathComponent("pan-grid-4096x3072.png"), to: file)
    let pipeline = LossPipeline { try FileManager.default.removeItem(at: file); return nil }
    let controller = try lossController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    let beforeSheet = lossObserveBeforeSheet(controller, window)
    defer { NotificationCenter.default.removeObserver(beforeSheet) }
    try await lossSettle(controller, file, pipeline)
    pipeline.holdHeader()
    defer { pipeline.releaseHeader() }
    controller.reconcileStandaloneImage()
    try await lossWait { pipeline.headerHeld }
    #expect(pipeline.headerHeld)
    pipeline.armLoader()
    controller.session.requireImageResolution(4096)
    try await lossWait { window.attachedSheet != nil }
    #expect(window.attachedSheet != nil)
    lossAssertCleared(controller, window)
    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    try await lossWait { window.attachedSheet == nil }
    let completed = pipeline.completedHeaderRequests
    pipeline.releaseHeader()
    try await lossWait { pipeline.completedHeaderRequests > completed }
    #expect(pipeline.completedHeaderRequests > completed)
    controller.reconcileStandaloneImage()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    lossAssertCleared(controller, window)
    #expect(window.attachedSheet == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233WakeAndVnodeDetectLossAndRetireObservers() async throws {
    // chmod generates .attrib, deliberately outside the vnode mask: wake must detect this loss.
    for wake in [true, false] {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let file = base.appendingPathComponent("image.png")
        let other = base.appendingPathComponent("replacement.png")
        try fm.copyItem(at: lossFixture(), to: file)
        try fm.copyItem(at: lossFixture(), to: other)
        let pipeline = LossPipeline { nil }
        let controller = try lossController(in: base, pipeline: pipeline)
        let window = try #require(controller.window)
        defer { window.close() }
        try await lossSettle(controller, file, pipeline)
        if wake {
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.hasImage)
            #expect(window.attachedSheet == nil)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await lossWait { window.attachedSheet != nil }
        } else {
            try fm.removeItem(at: file)
            try await lossWait { window.attachedSheet != nil }
        }
        #expect(window.attachedSheet != nil)
        lossAssertCleared(controller, window)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        try await lossWait { window.attachedSheet == nil }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
        controller.open(other, accessRequest: .fileGrant(other))
        try await lossWait { controller.session.imageLoader.phase == .settled }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.session.imageLoader.presented?.fileURL == other)
        #expect(window.attachedSheet == nil)
        window.close()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.attachedSheet == nil)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233ForegroundForwardingDetectsMissedFileGrantLoss() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: lossFixture(), to: file)
    let delegate = AppDelegate()
    let existing = Set(NSApplication.shared.windows.map(\.windowNumber))
    delegate.application(NSApplication.shared, open: [file])
    let window = try #require(NSApplication.shared.windows.first { !existing.contains($0.windowNumber) && $0.windowController is CanvasWindowController })
    let controller = try #require(window.windowController as? CanvasWindowController)
    defer { window.close() }
    try await lossWait { controller.session.imageLoader.phase == .settled }
    try await Task.sleep(for: .milliseconds(150))
    #expect(controller.route(.inspector, from: .key))
    try await lossWait { if case .known = controller.inspector.value { true } else { false } }
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.hasImage)
    #expect(window.attachedSheet == nil)
    delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    try await lossWait { window.attachedSheet != nil }
    #expect(window.attachedSheet != nil)
    lossAssertCleared(controller, window)
}

private final class LossScope: SecurityScope, @unchecked Sendable {
    let system = SystemSecurityScope()
    private let lock = NSLock()
    private var history: [URL] = []
    var urls: [URL] { lock.withLock { history } }
    func start(_ url: URL) -> Bool { lock.withLock { history.append(url) }; return system.start(url) }
    func stop(_ url: URL) { system.stop(url) }
    func isReadable(_ url: URL) -> Bool { system.isReadable(url) }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233ReconnectSelectionAndCancelStayFileScoped() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    let different = base.appendingPathComponent("portrait.png")
    try fm.copyItem(at: lossFixture(), to: file)
    try fm.copyItem(at: lossFixture().deletingLastPathComponent().appendingPathComponent("portrait-2x3.png"), to: different)
    let scope = LossScope()
    let pipeline = LossPipeline { nil }
    let controller = try lossController(in: base, pipeline: pipeline, scope: scope)
    let window = try #require(controller.window)
    defer { window.close() }
    for choice in [0, 1, 2, 3] {
        if !fm.fileExists(atPath: file.path) { try fm.copyItem(at: lossFixture(), to: file) }
        controller.open(file, accessRequest: .fileGrant(file))
        try await lossWait { controller.session.imageLoader.phase == .settled }
        if choice == 0 { #expect(controller.route(.inspector, from: .key)) }
        try await Task.sleep(for: .milliseconds(100))
        try await lossWait { if case .known = controller.inspector.value { true } else { false } }
        if case .known = controller.inspector.value {} else { Issue.record("Inspector must populate before reconnect loss") }
        try fm.removeItem(at: file)
        try await lossWait { window.attachedSheet != nil }
        lossAssertCleared(controller, window)
        let alert = try #require(window.attachedSheet)
        window.endSheet(alert, returnCode: choice == 0 ? .alertSecondButtonReturn : .alertFirstButtonReturn)
        if choice == 0 {
            try await lossWait { window.attachedSheet == nil }
            lossAssertCleared(controller, window)
            continue
        }
        try await lossWait { window.attachedSheet is NSOpenPanel }
        let panel = try #require(window.attachedSheet as? NSOpenPanel)
        #expect(!panel.canChooseDirectories)
        #expect(!panel.allowsMultipleSelection)
        #expect(panel.directoryURL?.standardizedFileURL == base.standardizedFileURL)
        if choice == 1 {
            window.endSheet(panel, returnCode: .cancel)
            try await lossWait { window.attachedSheet == nil }
            lossAssertCleared(controller, window)
        } else {
            let selected = choice == 2 ? file : different
            if choice == 2 { try fm.copyItem(at: lossFixture(), to: file) }
            // Accepted URLs use the same continuation as the production powerbox completion.
            // Actual powerbox acceptance is device-owned, not driven by xctest.
            controller.completeFileReconnection(selected, original: file)
            try await lossWait { controller.session.imageLoader.phase == .settled }
            #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == selected.standardizedFileURL)
            #expect(window.representedURL?.standardizedFileURL == selected.standardizedFileURL)
            try await lossWait { if case .known = controller.inspector.value { true } else { false } }
            guard case .known(let metadata) = controller.inspector.value else { Issue.record("Selected image metadata must load"); return }
            let width = try #require(metadata.pixelWidth)
            let height = try #require(metadata.pixelHeight)
            #expect(choice == 2 ? width > height : width < height)
            window.endSheet(panel, returnCode: .cancel)
            try await lossWait { window.attachedSheet == nil }
        }
    }
    // Resolve the original's filesystem alias while it exists again. Its reappearance must
    // not let a retired watch replace the different file accepted in the last episode.
    try fm.copyItem(at: lossFixture(), to: file)
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.session.imageLoader.presented?.fileURL.standardizedFileURL == different.standardizedFileURL)
    #expect(window.attachedSheet == nil)
    #expect(scope.urls.allSatisfy {
        let actual = $0.standardizedFileURL.resolvingSymlinksInPath()
        return actual == file.standardizedFileURL.resolvingSymlinksInPath()
            || actual == different.standardizedFileURL.resolvingSymlinksInPath()
    })
    #expect(!fm.fileExists(atPath: base.appendingPathComponent("roots.json").path))
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233SupersededReconcileFailureNeverAlerts() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    let other = base.appendingPathComponent("other.png")
    try fm.copyItem(at: lossFixture(), to: file)
    try fm.copyItem(at: lossFixture(), to: other)
    let pipeline = LossPipeline { nil }
    let controller = try lossController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    try await lossSettle(controller, file, pipeline)
    pipeline.holdHeader()
    defer { pipeline.releaseHeader() }
    controller.reconcileStandaloneImage()
    try await lossWait { pipeline.headerHeld }
    #expect(pipeline.headerHeld)
    controller.open(other, accessRequest: .fileGrant(other))
    try await lossWait { controller.session.imageLoader.phase == .settled }
    let current = try #require(controller.session.imageLoader.presented)
    try fm.removeItem(at: file)
    let completed = pipeline.completedHeaderRequests
    pipeline.releaseHeader()
    try await lossWait { pipeline.completedHeaderRequests > completed }
    #expect(pipeline.completedHeaderRequests > completed)
    #expect(controller.session.imageLoader.presented?.key == current.key)
    #expect(window.title == "other.png")
    #expect(window.representedURL == other)
    #expect(controller.inspector.name == "other.png")
    #expect(window.attachedSheet == nil)

    // Keep A's recovery context live while newer input B supersedes it. Cancelling A first
    // would mask a missing supersession guard by retiring the context before acceptance.
    try fm.copyItem(at: lossFixture(), to: file)
    controller.open(file, accessRequest: .fileGrant(file))
    try await lossWait { controller.session.imageLoader.phase == .settled }
    try await Task.sleep(for: .milliseconds(100))
    try fm.removeItem(at: file)
    try await lossWait { window.attachedSheet != nil }
    let alert = try #require(window.attachedSheet)
    window.endSheet(alert, returnCode: .alertFirstButtonReturn)
    try await lossWait { window.attachedSheet is NSOpenPanel }
    let panel = try #require(window.attachedSheet as? NSOpenPanel)
    try fm.copyItem(at: lossFixture(), to: file)
    controller.openInput([other])
    try await lossWait { controller.session.imageLoader.phase == .settled && window.representedURL == other }
    let replacement = try #require(controller.session.imageLoader.presented)
    #expect(window.attachedSheet === panel)
    controller.completeFileReconnection(file, original: file)
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.session.imageLoader.presented?.key == replacement.key)
    #expect(window.representedURL == other)
    #expect(window.title == "other.png")
    #expect(controller.inspector.name == "other.png")
    window.endSheet(panel, returnCode: .cancel)
    try await lossWait { window.attachedSheet == nil }
    controller.completeFileReconnection(file, original: file)
    controller.completeFileReconnection(nil, original: file)
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.session.imageLoader.presented?.key == replacement.key)
    #expect(window.representedURL == other)
    #expect(window.title == "other.png")
    #expect(controller.inspector.name == "other.png")
    #expect(window.attachedSheet == nil)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue233ReconcileLossClearsBeforeSheet() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: lossFixture(), to: file)
    let pipeline = LossPipeline { try FileManager.default.removeItem(at: file); return nil }
    let controller = try lossController(in: base, pipeline: pipeline)
    let window = try #require(controller.window)
    defer { window.close() }
    let beforeSheet = lossObserveBeforeSheet(controller, window)
    defer { NotificationCenter.default.removeObserver(beforeSheet) }
    try await lossSettle(controller, file, pipeline)
    pipeline.arm()
    controller.reconcileStandaloneImage()
    try await lossWait { window.attachedSheet != nil }
    #expect(window.attachedSheet != nil)
    lossAssertCleared(controller, window)
    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    try await lossWait { window.attachedSheet == nil }
    controller.reconcileStandaloneImage()
    try await Task.sleep(for: .milliseconds(100))
    lossAssertCleared(controller, window)
    #expect(window.attachedSheet == nil)
}
