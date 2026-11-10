import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private enum Issue630ReconciliationOrigin {
    @TaskLocal static var token: UUID? = nil
}

/// Delays only a failure the native adapter has already produced; no access result is substituted.
private final class Issue630NativeFailureGate: SecurityScope, BookmarkCoding, @unchecked Sendable {
    private let native = SystemSecurityScope()
    private let condition = NSCondition()
    private var armed = false
    private var released = true
    private var failure: String?
    private var expectedOrigin: UUID?
    private var failureOrigin: UUID?
    private let bookmarkLock = NSLock()
    private var bookmark: Data?

    var requiresEmbeddedIdentity: Bool { native.requiresEmbeddedIdentity }
    var capturedFailure: String? { condition.lock(); defer { condition.unlock() }; return failure }
    var capturedOrigin: UUID? { condition.lock(); defer { condition.unlock() }; return failureOrigin }
    func arm(origin: UUID) {
        condition.lock()
        armed = true; released = false; failure = nil; failureOrigin = nil; expectedOrigin = origin
        condition.unlock()
    }
    func release() {
        condition.lock(); armed = false; released = true; condition.broadcast(); condition.unlock()
    }
    private func hold(_ provenance: String) {
        condition.lock()
        if armed, Issue630ReconciliationOrigin.token == expectedOrigin {
            armed = false
            // A native result must never be held on the UI thread: decline the
            // experiment so its named setup precondition fails instead of deadlocking.
            guard !Thread.isMainThread else { condition.unlock(); return }
            failure = provenance
            failureOrigin = Issue630ReconciliationOrigin.token
            while !released { condition.wait() }
        }
        condition.unlock()
    }
    func start(_ url: URL) -> Bool { native.start(url) }
    func stop(_ url: URL) { native.stop(url) }
    func isReadable(_ url: URL) -> Bool {
        let result = native.isReadable(url)
        if !result { hold("native isReadable=false file=\(url.lastPathComponent)") }
        return result
    }
    func create(for url: URL) throws -> Data {
        let data = try native.create(for: url)
        bookmarkLock.withLock { bookmark = data }
        return data
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        do { return try native.resolve(data) }
        catch {
            let actual = error as NSError
            hold("native resolve error=\(actual.domain):\(actual.code)")
            throw error
        }
    }
    /// Independent native observation while FileAccess is held in the forwarding boundary.
    func nativeDestination() throws -> URL {
        let data = try #require(bookmarkLock.withLock { bookmark }, "native bookmark creation precondition")
        return try native.resolve(data).url
    }
}

private final class Issue630Pipeline: ImagePipeline, @unchecked Sendable {
    private let native = ImageIOPipeline()
    private let lock = NSLock()
    private var headers = 0
    var completedHeaders: Int { lock.withLock { headers } }
    func request(for url: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        let result = try await native.request(for: url, maximumPixelSize: maximumPixelSize)
        lock.withLock { headers += 1 }
        return result
    }
    func request(for url: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        try await native.request(for: url, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage { try await native.image(for: request) }
}

@MainActor private final class Issue630Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private enum Issue630Destination: Equatable { case trash, unlink, moved }

@MainActor private final class Issue630ReconciliationFixture {
    let base: URL
    let file: URL
    let deniedDirectory: URL
    let deniedFile: URL
    let gate = Issue630NativeFailureGate()
    let pipeline = Issue630Pipeline()
    let controller: CanvasWindowController
    var trashed: NSURL?
    var heldTask: Task<Void, Never>?
    var completionObserver: Task<Void, Never>?
    var reconciliationEnded = false
    var window: NSWindow { controller.window! }

    init() throws {
        _ = NSApplication.shared
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = base.appendingPathComponent("issue630.png")
        deniedDirectory = base.appendingPathComponent("denied", isDirectory: true)
        deniedFile = deniedDirectory.appendingPathComponent("issue630.png")
        try FileManager.default.createDirectory(at: deniedDirectory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
        try FileManager.default.copyItem(at: source, to: file)
        let access = try FileAccess(scope: gate, bookmarks: gate,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue630")
        let services = AccessServices(files: access,
            recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
            watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
        controller = CanvasWindowController(pipeline: pipeline,
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
            motionPolicy: MotionPolicy(source: Issue630Motion()))
    }

    func exercise(_ destination: Issue630Destination) async throws {
        controller.open(file, accessRequest: .fileGrant(file))
        try await waitUntil { self.controller.session.imageLoader.phase == .settled && self.pipeline.completedHeaders > 0 }
        await controller.waitForStandaloneReconciliation()
        try #require(controller.session.imageLoader.presented != nil)
        try #require(window.attachedSheet == nil)
        _ = try gate.nativeDestination()

        // No MainActor suspension lets a vnode callback start work between this move and our explicit task.
        try FileManager.default.moveItem(at: file, to: deniedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedDirectory.path)
        var denied = false
        do { try FileHandle(forReadingFrom: deniedFile).close() } catch { denied = true }
        try #require(denied, "native FileHandle denial precondition was not reached")
        let origin = UUID()
        gate.arm(origin: origin)
        let owned = Issue630ReconciliationOrigin.$token.withValue(origin) {
            controller.reconcileStandaloneImage()
        }
        let task = try #require(owned)
        heldTask = task
        completionObserver = Task { await task.value; self.reconciliationEnded = true }
        try await waitUntil("native failure capture or reconciliation completion") {
            self.gate.capturedFailure != nil || self.reconciliationEnded
        }
        let provenance = try #require(gate.capturedFailure,
            "native failure gate precondition was not reached before reconciliation ended")
        try #require(gate.capturedOrigin == origin, "held failure must belong to the awaited reconciliation")
        print("issue630 held reconciliation: \(provenance) origin=\(origin)")
        try #require(!reconciliationEnded)
        try #require(window.attachedSheet == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDirectory.path)
        let moved = base.appendingPathComponent("readable.png")
        switch destination {
        case .trash:
            try FileManager.default.trashItem(at: deniedFile, resultingItemURL: &trashed)
            let trashURL = try #require(trashed) as URL
            try #require(normalized(try gate.nativeDestination()) == normalized(trashURL),
                "native bookmark must independently follow the original inode into the real Trash")
        case .unlink:
            try FileManager.default.removeItem(at: deniedFile)
            try #require(!FileManager.default.fileExists(atPath: deniedFile.path))
        case .moved:
            try FileManager.default.moveItem(at: deniedFile, to: moved)
            try FileHandle(forReadingFrom: moved).close()
            try #require(normalized(try gate.nativeDestination()) == normalized(moved))
        }
        try #require(window.attachedSheet == nil)
        gate.release()
        await task.value
        await controller.waitForStandaloneReconciliation()

        switch destination {
        case .trash, .unlink:
            #expect(controller.session.imageLoader.fileURL == nil)
            #expect(controller.session.imageLoader.presented == nil)
            #expect(window.representedURL == nil)
            if destination == .trash {
                #expect(window.attachedSheet == nil, "sheet: \(sheetText(window))")
            } else {
                #expect(window.attachedSheet != nil)
                #expect(sheetText(window).contains(String(localized: "Choose this image again to reconnect access.")))
            }
        case .moved:
            try await waitUntil {
                self.controller.session.imageLoader.phase == .settled || self.window.attachedSheet != nil
            }
            #expect(controller.session.imageLoader.fileURL.map(normalized) == normalized(moved))
            #expect(controller.session.imageLoader.presented.map { normalized($0.fileURL) } == normalized(moved))
            #expect(window.representedURL.map(normalized) == normalized(moved))
            #expect(window.attachedSheet == nil, "sheet: \(sheetText(window))")
        }
    }

    func clean() async {
        gate.release()
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDirectory.path)
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
        window.close()
        await heldTask?.value
        await completionObserver?.value
        await controller.waitForStandaloneReconciliation()
        if let trashed { try? FileManager.default.removeItem(at: trashed as URL) }
        try? FileManager.default.removeItem(at: base)
    }
    private func normalized(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue630DelayedNativeAccessFailureAfterTrashDoesNotReconnect() async throws {
    let f = try Issue630ReconciliationFixture()
    try await withAsyncTeardown { try await f.exercise(.trash) } teardown: { await f.clean() }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue630DelayedNativeAccessFailureAfterUnlinkReconnects() async throws {
    let f = try Issue630ReconciliationFixture()
    try await withAsyncTeardown { try await f.exercise(.unlink) } teardown: { await f.clean() }
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue630DelayedNativeAccessFailureFollowsReadableMove() async throws {
    let f = try Issue630ReconciliationFixture()
    try await withAsyncTeardown { try await f.exercise(.moved) } teardown: { await f.clean() }
}
