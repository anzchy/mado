import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class GridEntryHost: ViewerSessionHost, ViewerImageHost {
    var hasImage = false
    var installed: [URL] = []
    var inspectorVisible = false
    var focus: FocusContext = .canvas
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) { self.focus = focus }
    func showInspector(_ visible: Bool) { inspectorVisible = visible }
    func beginImageOpening() { hasImage = false }
    func installImage(_ image: DecodedImage, fileURL: URL) { hasImage = true; installed.append(fileURL) }
    func imageLoadFailed(_ error: any Error) { hasImage = false }
}

private actor GridEntryLeases: AccessLeasing {
    var acquired = 0
    var released = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func acquire(_ request: AccessRequest) -> AccessLease {
        acquired += 1
        switch request {
        case .fileGrant(let url), .root(_, let url): return AccessLease(url: url, rootID: nil)
        }
    }
    func release(_ lease: AccessLease) {
        released += 1
        if acquired == released { waiter?.resume(); waiter = nil }
    }
    func waitUntilBalanced() async {
        if acquired == released { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor HeldGridDecode: ImagePipeline {
    let base = LoadPipeline()
    private var didHold = false
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func request(for fileURL: URL, maximumPixelSize: Int) async -> ImageDecodeRequest {
        await base.request(for: fileURL, maximumPixelSize: maximumPixelSize)
    }
    func image(for request: ImageDecodeRequest) async -> DecodedImage {
        if !didHold {
            didHold = true
            await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
        }
        return loadImage(request.renderKey!, edge: request.maximumPixelSize)
    }
    func entered() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func resume() { pending?.resume(); pending = nil }
}

@Test @MainActor func gridEntryRetiresSettledImageLeaseAndInspectorBeforeNewSource() async throws {
    let session = ViewerSession(), host = GridEntryHost(), leases = GridEntryLeases(), pipeline = LoadPipeline()
    session.host = host; session.imageLoader.host = host
    let a = URL(fileURLWithPath: "/tmp/grid-old-A.png")
    session.openImage(a, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(a), access: leases, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    #expect(host.installed.last == a)
    let initialAcquired = await leases.acquired, initialReleased = await leases.released
    #expect(initialAcquired > initialReleased)
    session.setInspectorVisible(true)
    session.updateFocus(.textInput)
    session.enterFolderGrid(items: [], sourceVersion: .init(1))
    #expect(session.mode == .browsing)
    #expect(session.imageLoader.fileURL == nil)
    #expect(session.imageLoader.phase == .idle)
    #expect(!session.isEnabled(.fit) && !session.isEnabled(.inspector))
    #expect(!session.inspectorFocus.isVisible && session.inspectorFocus.focus == .canvas)
    #expect(!host.inspectorVisible && host.focus == .canvas)
    guard session.imageLoader.fileURL == nil else { session.closeImage(); return }
    await leases.waitUntilBalanced()
    let acquired = await leases.acquired, released = await leases.released
    #expect(acquired == released)
    let c = URL(fileURLWithPath: "/tmp/grid-independent-C.png")
    session.leaveBrowsing()
    session.openImage(c, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(c), access: leases, pipeline: pipeline) }
    await session.imageLoader.loadTask?.value
    #expect(host.installed.last == c)
    session.closeImage()
}

@Test @MainActor func gridEntryRejectsLateOldDecodeWithoutCancellingNewBrowseState() async throws {
    let session = ViewerSession(), host = GridEntryHost(), leases = GridEntryLeases(), pipeline = HeldGridDecode()
    session.host = host; session.imageLoader.host = host
    let a = URL(fileURLWithPath: "/tmp/grid-delayed-A.png")
    session.openImage(a, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(a), access: leases, pipeline: pipeline) }
    let oldTask = session.imageLoader.loadTask
    await pipeline.entered()
    let oldGeneration = session.imageLoader.generation
    session.enterFolderGrid(items: [], sourceVersion: .init(2))
    #expect(session.imageLoader.generation != oldGeneration)
    #expect(session.mode == .browsing && session.imageLoader.fileURL == nil)
    await pipeline.resume()
    guard session.imageLoader.generation != oldGeneration else { session.closeImage(); return }
    await oldTask?.value
    guard session.imageLoader.fileURL == nil else { session.closeImage(); return }
    await leases.waitUntilBalanced()
    #expect(host.installed.isEmpty)
    let acquired = await leases.acquired, released = await leases.released
    #expect(acquired == released)
    #expect(session.mode == .browsing && session.imageLoader.phase == .idle)
}

@Test @MainActor func gridEntryKeepsNewFolderScanAuthorizedThroughLaterBatch() async throws {
    let fixture = FolderScanFixture()
    let session = ViewerSession()
    session.folderScan = fixture.coordinator
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    session.enterFolderGrid(items: [], sourceVersion: .init(1))
    #expect(fixture.coordinator.isReadingFolder)
    try await fixture.scanner.deliver(["B.jpg"])
    #expect(fixture.coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["B.jpg"])
    await fixture.scanner.finish()
    try await task.value
    let acquired = await fixture.access.acquired, released = await fixture.access.released
    #expect(acquired == released)
}
