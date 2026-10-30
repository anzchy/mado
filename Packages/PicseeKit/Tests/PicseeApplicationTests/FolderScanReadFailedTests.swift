import Foundation
import Testing
import PicseeCore
@testable import PicseeApplication

/// #238 (P3-17c D3): 「读取失败」 (24F-A) and its boundary with page 26.
enum ReadFailedErrorKind: CaseIterable, Sendable {
    case io, denied, cocoaDenied, gone
    var error: any Error & Sendable {
        switch self {
        case .io: POSIXError(.EIO)
        case .denied: POSIXError(.EACCES)
        case .cocoaDenied: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        case .gone: POSIXError(.ENOENT)
        }
    }
    var reason: String {
        switch self {
        case .io, .gone: "Folder scan failed"
        case .denied, .cocoaDenied: "Folder access denied"
        }
    }
}

@MainActor final class ReadFailedHost: FolderScanHost, ViewerSessionNavigationHost, ViewerInputHost {
    var log: [String] = []
    var openRequests = 0
    var hasImage = false
    var canNavigate = true
    func openFolderImage(_ url: URL, rootID: AccessRootID) { log.append("open-\(url.lastPathComponent)") }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { log.append("remember") }
    func clearFolderImageForNoMatches() { log.append("clear") }
    func folderScanDidComplete(count: Int) { log.append("complete-\(count)") }
    func folderScanDidStart() { log.append("start") }
    func folderScanDidEnd() { log.append("end") }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) { }
    func showInputNotice(_ notice: ViewerInputNotice) { }
    func promptForInputFolder(_ folder: URL) { }
    func navigate(_ direction: NavigationDirection) { }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func requestOpen() { openRequests += 1 }
    func applyFocus(_ focus: FocusContext) { }
    func showInspector(_ visible: Bool) { }
    /// Events after the last `start`, which the scan under test owns.
    var sinceStart: [String] { Array(log[((log.lastIndex(of: "start") ?? -1) + 1)...]) }
}

/// Same domain and code, since POSIXError and NSError bridge.
func readFailedSameError(_ lhs: (any Error)?, _ rhs: any Error) -> Bool {
    guard let lhs else { return false }
    let a = lhs as NSError, b = rhs as NSError
    return a.domain == b.domain && a.code == b.code
}

@MainActor private func readFailedScene(_ name: String = "待整理")
    -> (FolderScanFixture, FolderScanCoordinator, ViewerSession, ReadFailedHost, URL) {
    let fixture = FolderScanFixture(), host = ReadFailedHost()
    let session = ViewerSession(host: host), coordinator = fixture.coordinator
    session.folderScan = coordinator; coordinator.host = host
    return (fixture, coordinator, session, host, fixture.root.appendingPathComponent(name))
}

// MARK: WI-1 — the failure state carries the folder name; a folder-entry failure keeps nothing partial.

@Test(arguments: [0, 1, 2, 3], ReadFailedErrorKind.allCases)
@MainActor func readFailedFolderEntryNeverPublishesPartialAsComplete(cut: Int, kind: ReadFailedErrorKind) async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    for index in 0..<cut {
        try await fixture.scanner.deliver(["img\(index).png"])
        #expect(!host.log.contains { $0.hasPrefix("complete-") }, "batch \(index)")
        #expect(coordinator.completedImageCount == nil, "batch \(index)")
    }
    await fixture.scanner.finish(failing: true, error: kind.error)
    var thrown: (any Error)?
    do { try await task.value } catch { thrown = error }
    #expect(readFailedSameError(thrown, kind.error))
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil)
    #expect(coordinator.completedImageCount == nil && !session.hasFolderSource)
    #expect(coordinator.failure != nil && !coordinator.isScanning && !coordinator.isReadingFolder)
    #expect(session.imageStatus == .folderScanFailed(kind.reason, "待整理"))
    #expect(host.sinceStart == ["end"])
    #expect(!host.log.contains { $0.hasPrefix("complete-") || $0.hasPrefix("open-") })
    #expect(await fixture.access.balance == [1, 1])
}

@Test @MainActor func readFailedAcquireFailureIsAReadFailureWithNoLease() async throws {
    let fixture = FolderScanFixture(fails: true), host = ReadFailedHost()
    let session = ViewerSession(host: host), coordinator = fixture.coordinator
    session.folderScan = coordinator; coordinator.host = host
    let folder = fixture.root.appendingPathComponent("待整理")
    await #expect(throws: FolderScanTestError.expected) { try await coordinator.begin(folder: folder, rootID: fixture.id).value }
    #expect(coordinator.snapshot == nil && coordinator.sourceSnapshot == nil)
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "待整理"))
    #expect(host.sinceStart == ["end"])
    #expect(await fixture.access.balance == [0, 0])
    #expect(await fixture.scanner.startedCount == 0)
}

@Test(arguments: ["待整理", "A"])
@MainActor func readFailedStatusNamesTheFolderNotACount(name: String) async throws {
    let (fixture, coordinator, session, _, folder) = readFailedScene(name)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png"])
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", name))
}

@Test @MainActor func readFailedFolderEntryRetryRescansWithoutSnapshot() async throws {
    let (fixture, coordinator, session, host, folder) = readFailedScene()
    _ = coordinator.setRecursiveEnabled(true)
    let task = coordinator.begin(folder: folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"])
    coordinator.setConditions(.init(sort: .name, direction: .descending, selectedExtensions: ["png"]))
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(coordinator.sourceSnapshot == nil)
    let before = coordinator.conditions
    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    #expect(await fixture.scanner.startedCount == 2)
    #expect(await fixture.scanner.folder(at: 1) == folder)
    #expect(await fixture.scanner.options(at: 1).recursive)
    #expect(coordinator.conditions == before)
    #expect(coordinator.isReadingFolder && session.imageStatus == .readingFolder)
    #expect(await fixture.access.requests == [.root(fixture.id, file: folder), .root(fixture.id, file: folder)])
    #expect(host.log.last == "start")
    coordinator.cancel()
    await fixture.scanner.finish(1); _ = try? await retry.value
}

@Test(arguments: [0, 1, 3])
@MainActor func readFailedImageFirstKeepsKnownImagesNavigable(count: Int) async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let coordinator = fixture.coordinator, session = ViewerSession(host: host)
    session.folderScan = coordinator; coordinator.host = host
    let input = fixture.folder.appendingPathComponent("img2.png")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    if count > 0 { try await fixture.scanner.deliver(count == 1 ? ["img2.png"] : ["img1.png", "img2.png", "img10.png"]) }
    await fixture.scanner.finish(failing: true, error: ReadFailedErrorKind.io.error)
    _ = try? await task.value
    #expect(coordinator.snapshot?.entries.count == count)
    #expect(coordinator.canMove(.next) == (count == 3) && coordinator.canMove(.previous) == (count == 3))
    #expect(coordinator.currentURL == input)
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "A"))
    #expect(host.opens.isEmpty)
    #expect(await fixture.access.balance == [1, 1])
}
