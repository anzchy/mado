import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

/// A held external read: real projection/chrome run before and after the enumeration terminates.
private actor I142ChromeScanner: FolderScanning {
    private var nextIndex = 0
    private var endings: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let index = nextIndex; nextIndex += 1
        try await emit(["a.png", "b.jpg", "c.png"].map { FolderEntry(url: folder.appendingPathComponent($0), root: root) })
        try await withCheckedThrowingContinuation { continuation in
            endings[index] = continuation
            waiters.removeValue(forKey: index)?.resume()
        }
    }
    func started(_ index: Int) async {
        if endings[index] == nil { await withCheckedContinuation { waiters[index] = $0 } }
    }
    func finish(_ index: Int, failed: Bool = false) {
        let ending = endings.removeValue(forKey: index)
        if failed { ending?.resume(throwing: CocoaError(.fileReadUnknown)) }
        else { ending?.resume() }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func i142WI2RenderedChromeFollowsScanProjectionCancelAndFailure() async throws {
    let scene = StatesScene(), scanner = I142ChromeScanner()
    defer { scene.window.close() }
    let folder = URL(fileURLWithPath: "/i142-chrome/A"), root = AccessRootID()
    let c = FolderScanCoordinator(access: StatesLeases(), scanner: scanner)
    scene.session.folderScan = c
    let label = try #require(scene.chrome.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityIdentifier() == "chrome.filename" })
    func expectText(_ expected: String) {
        for _ in 0..<2 {
            scene.chrome.refresh(session: scene.session)
            #expect(label.stringValue == expected)
        }
    }
    let reading = String(localized: "Reading…")
    func images(_ count: Int) -> String {
        String(format: String(localized: "Images: %lld"), Int64(count))
    }
    expectText("")
    let task = c.begin(folder: folder, rootID: root)
    expectText(reading)
    await scanner.started(0)
    #expect(c.snapshot?.isComplete == false && c.completedImageCount == nil)
    expectText(reading)
    await scanner.finish(0)
    try await task.value
    for (extensions, count) in [(nil as Set<String>?, 3), (["png"], 2), (["gif"], 0), (nil, 3)] {
        c.setConditions(.init(selectedExtensions: extensions))
        expectText(images(count))
        #expect(c.completedImageCount == count)
    }
    c.setConditions(.init(selectedExtensions: ["png"]))
    scene.session.beginFolderEntry(shownImage: nil, hasCompleteGrid: true)
    let replacement = c.begin(folder: folder.deletingLastPathComponent().appendingPathComponent("B"), rootID: root)
    await scanner.started(1)
    expectText(reading)
    #expect(scene.session.cancelFolderEntry() == .grid)
    expectText(images(2))
    await scanner.finish(1)
    try await replacement.value
    expectText(images(2))
    let failing = c.begin(folder: folder, rootID: root)
    await scanner.started(2)
    expectText(reading)
    await scanner.finish(2, failed: true)
    await #expect(throws: CocoaError.self) { try await failing.value }
    #expect(c.completedImageCount == nil && c.failure != nil)
    expectText("")
}
