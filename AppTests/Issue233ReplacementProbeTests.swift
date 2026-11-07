import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// Blocks only the synchronous system adapter on FileAccess's executor, never MainActor.
private final class ReplacementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var waiting = false
    func arm() { condition.lock(); armed = true; condition.unlock() }
    var held: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
    func enter() {
        condition.lock()
        if armed {
            armed = false; waiting = true
            while waiting { condition.wait() }
        }
        condition.unlock()
    }
    func release() { condition.lock(); armed = false; waiting = false; condition.broadcast(); condition.unlock() }
}

private final class ReplacementIdentity: FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var next: URL?
    private var visits = 0
    var count: Int { lock.withLock { visits } }
    func useNext(_ url: URL) { lock.withLock { next = url } }
    func identity(for file: URL) throws -> FileResourceIdentity? {
        let alternate = lock.withLock { () -> URL? in visits += 1; defer { next = nil }; return next }
        return try URLIdentityResourceReader().identity(for: alternate ?? file)
    }
}

private final class ReplacementScope: SecurityScope, @unchecked Sendable {
    let releaseGate = ReplacementGate()
    let identity: ReplacementIdentity
    let alternate: URL
    private let lock = NSLock()
    private var denyRead = false
    private var denyScope = false
    private var sessions = 0
    private var starts = 0
    init(identity: ReplacementIdentity, alternate: URL) { self.identity = identity; self.alternate = alternate }
    var active: Int { lock.withLock { sessions } }
    var startCount: Int { lock.withLock { starts } }
    func armReadDenial() { lock.withLock { denyRead = true }; releaseGate.arm() }
    func armScopeDenial() { lock.withLock { denyScope = true } }
    func start(_ url: URL) -> Bool {
        let mode = lock.withLock { () -> Int in
            starts += 1
            if denyScope { denyScope = false; return 2 }
            sessions += 1
            if denyRead { denyRead = false; return 1 }
            return 0
        }
        if mode == 2 { identity.useNext(alternate); return false }
        if mode == 1 { try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
        // The test controls scope lifetime; actual FileHandle reads still enforce real POSIX permissions.
        return true
    }
    func isReadable(_ url: URL) -> Bool { false } // Only reached for the one-shot denied scope.
    func stop(_ url: URL) { releaseGate.enter(); lock.withLock { sessions -= 1 } }
}

private final class ReplacementBookmarks: BookmarkCoding, @unchecked Sendable {
    let gate = ReplacementGate()
    private let system = SystemSecurityScope()
    private let lock = NSLock()
    private var queued: [(Result<URL, CocoaError>, Bool)] = []
    func arm(_ result: Result<URL, CocoaError>, held: Bool) {
        lock.withLock { queued.append((result, held)) }
    }
    func create(for url: URL) throws -> Data { try system.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let result = lock.withLock { queued.isEmpty ? nil : queued.removeFirst() }
        guard let (value, held) = result else { return try system.resolve(data) }
        if held { gate.arm(); gate.enter() }
        return try ResolvedBookmark(url: value.get(), stale: false)
    }
}

private final class ReplacementPipeline: ImagePipeline, @unchecked Sendable {
    private let base = ImageIOPipeline()
    private let lock = NSLock()
    private var headers = 0
    var headerCount: Int { lock.withLock { headers } }
    func request(for url: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        lock.withLock { headers += 1 }
        return try await base.request(for: url, maximumPixelSize: maximumPixelSize)
    }
    func request(for url: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await base.request(for: url, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage { try await base.image(for: request) }
}

@MainActor private final class ReplacementMotion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func replacementWait(
    fileID: String = #fileID, line: Int = #line, _ condition: @MainActor () -> Bool
) async throws {
    try await waitUntil(fileID: fileID, line: line) { condition() }
}

/// Each argument holds one of the four actual post-read/resolution delivery continuations.
@Test(.timeLimit(.minutes(3)), arguments: ["failedReadRelease", "successfulReadRelease", "bookmarkSuccess", "bookmarkFailure"])
@MainActor func issue233ReplacedProbeHeldCompletionsNeverDeliver(_ boundary: String) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let original = base.appendingPathComponent("probe-a.png")
    let alternate = base.appendingPathComponent("probe-b.png")
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic")
    try fm.copyItem(at: fixtures.appendingPathComponent("landscape-3x2.png"), to: original)
    try fm.copyItem(at: fixtures.appendingPathComponent("portrait-2x3.png"), to: alternate)
    let identity = ReplacementIdentity()
    let scope = ReplacementScope(identity: identity, alternate: alternate)
    let bookmarks = ReplacementBookmarks()
    let pipeline = ReplacementPipeline()
    let files = try FileAccess(scope: scope, bookmarks: bookmarks,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue233-fix1", resourceReader: identity)
    let services = AccessServices(files: files, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(), watch: WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let viewer = CanvasWindowController(pipeline: pipeline, preferencesStore: InMemoryDisplayPreferencesStore(),
        accessServices: Task { services }, motionPolicy: MotionPolicy(source: ReplacementMotion()))
    let window = try #require(viewer.window)
    defer {
        scope.releaseGate.release(); bookmarks.gate.release()
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        window.close()
        try? fm.removeItem(at: base)
    }
    viewer.open(original, accessRequest: .fileGrant(original))
    try await replacementWait { viewer.session.imageLoader.phase == .settled && pipeline.headerCount > 0 }
    #expect(viewer.hasImage)
    #expect(viewer.route(.inspector, from: .key))
    try await replacementWait { if case .known = viewer.inspector.value { true } else { false } }
    if case .known = viewer.inspector.value {} else { Issue.record("Inspector must be populated before replacement") }
    // Complete the startup access work before arming a single system-boundary gate.
    await viewer.reportFileGrantReadFailure(original).value
    try await Task.sleep(for: .milliseconds(100))
    let presented = try #require(viewer.session.imageLoader.presented)
    let generation = viewer.session.imageLoader.generation
    let phase = viewer.session.imageLoader.phase
    let title = window.title
    let represented = window.representedURL
    let name = viewer.inspector.name
    let metadata = viewer.inspector.value
    let headers = pipeline.headerCount
    var sheets = 0
    let observer = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { _ in
        MainActor.assumeIsolated { sheets += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    // The displayed source retains A's lease. Resolve P1 to B so its release is independent.
    identity.useNext(alternate)
    bookmarks.arm(.success(alternate), held: false)
    switch boundary {
    case "failedReadRelease": scope.armReadDenial()
    case "successfulReadRelease": scope.releaseGate.arm()
    default:
        scope.armScopeDenial()
        bookmarks.arm(boundary == "bookmarkSuccess" ? .success(original) : .failure(CocoaError(.fileReadNoPermission)), held: true)
    }
    let p1 = viewer.reportFileGrantReadFailure(original)
    let gate = boundary.hasSuffix("Release") ? scope.releaseGate : bookmarks.gate
    try await replacementWait { gate.held }
    try #require(gate.held, "P1 must reach the held \(boundary) boundary")
    if boundary == "failedReadRelease" {
        do {
            let handle = try FileHandle(forReadingFrom: alternate)
            try handle.close()
            Issue.record("Held release must follow a real non-cancellation permission error")
        } catch {
            #expect(!(error is CancellationError))
            #expect(AccessReadFailure.isPermissionDenied(error))
        }
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: alternate.path)
    let identities = identity.count
    let p2 = viewer.reportFileGrantReadFailure(original)
    #expect(p1.isCancelled)
    #expect(!p2.isCancelled)
    #expect(viewer.session.imageLoader.generation == generation)
    #expect(viewer.session.imageLoader.presented?.key == presented.key)
    gate.release()
    await p1.value
    await p2.value
    #expect(identity.count > identities, "P2 must acquire before the explicit actor drain")
    // Drain actual FileAccess work and any reconcile scheduled by the stale successful continuation.
    _ = try await files.resolveFileGrant(original)
    try await Task.sleep(for: .milliseconds(150))
    #expect(!p2.isCancelled, "replacement P2 must remain current")
    #expect(identity.count > identities, "P2 must actually acquire the original file after replacing P1")
    #expect(sheets == 0, "retired P1 must never deliver a loss boundary or alert")
    #expect(window.attachedSheet == nil)
    #expect(viewer.hasImage)
    #expect(viewer.session.imageLoader.generation == generation)
    #expect(viewer.session.imageLoader.fileURL == original)
    #expect(viewer.session.imageLoader.phase == phase)
    #expect(viewer.session.imageLoader.presented?.key == presented.key)
    #expect(window.title == title)
    #expect(window.representedURL == represented)
    #expect(viewer.inspector.name == name)
    #expect(viewer.inspector.value == metadata)
    #expect(pipeline.headerCount == headers, "retired successful P1 must not trigger a new reconciliation read")
    #expect(!fm.fileExists(atPath: base.appendingPathComponent("roots.json").path))
}
