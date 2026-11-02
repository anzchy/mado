import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

/// A held external read: real projection/chrome run before and after the enumeration terminates.
private actor I142ChromeScanner: FolderScanning {
    private var nextIndex = 0
    private var endings: [Int: CheckedContinuation<Void, any Error>] = [:]
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try Task.checkCancellation()
        let index = nextIndex; nextIndex += 1
        try await emit(["a.png", "b.jpg", "c.png"].map { FolderEntry(url: folder.appendingPathComponent($0), root: root) })
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            endings[index] = continuation
        }
    }
    func started(_ index: Int) -> Bool { endings[index] != nil }
    func finishAll() {
        let pending = Array(endings.values)
        endings.removeAll()
        for ending in pending { ending.resume(throwing: CancellationError()) }
    }
    func finish(_ index: Int, failed: Bool = false) {
        let ending = endings.removeValue(forKey: index)
        if failed { ending?.resume(throwing: CocoaError(.fileReadUnknown)) }
        else { ending?.resume() }
    }
}

/// Yield the MainActor until the scan reaches its held gate; the test time limit bounds the wait.
private func i142ChromeStarted(_ scanner: I142ChromeScanner, _ index: Int) async throws -> Bool {
    while !(await scanner.started(index)) {
        try await Task.sleep(for: .milliseconds(5))
    }
    return await scanner.started(index)
}

@Test(.timeLimit(.minutes(2))) @MainActor func i142WI2RenderedChromeFollowsScanProjectionCancelAndFailure() async throws {
    let scene = StatesScene(), scanner = I142ChromeScanner()
    defer { scene.window.close() }
    let folder = URL(fileURLWithPath: "/i142-chrome/A"), root = AccessRootID()
    let c = FolderScanCoordinator(access: StatesLeases(), scanner: scanner)
    try await withAsyncTeardown { @MainActor in
        scene.session.folderScan = c
        let label = try #require(scene.chrome.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "chrome.filename" })
        @MainActor func expectText(_ expected: String) {
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
        await Task.yield()
        let task = c.begin(folder: folder, rootID: root)
        expectText(reading)
        try #require(await i142ChromeStarted(scanner, 0), "Scan phase 0 did not reach its held gate")
        #expect(c.snapshot?.isComplete == false && c.completedImageCount == nil)
        expectText(reading)
        await scanner.finish(0)
        try await task.value
        for (extensions, count) in [(nil as Set<String>?, 3), (["png"], 2), (["gif"], 0), (nil, 3)] {
            c.setConditions(.init(selectedExtensions: extensions))
            expectText(images(count))
            #expect(c.completedImageCount == count)
            await Task.yield()
        }
        c.setConditions(.init(selectedExtensions: ["png"]))
        scene.session.beginFolderEntry(shownImage: nil, hasCompleteGrid: true)
        await Task.yield()
        let replacement = c.begin(folder: folder.deletingLastPathComponent().appendingPathComponent("B"), rootID: root)
        try #require(await i142ChromeStarted(scanner, 1), "Scan phase 1 did not reach its held gate")
        expectText(reading)
        #expect(scene.session.cancelFolderEntry() == .grid)
        expectText(images(2))
        await scanner.finish(1)
        try await replacement.value
        expectText(images(2))
        await Task.yield()
        let failing = c.begin(folder: folder, rootID: root)
        try #require(await i142ChromeStarted(scanner, 2), "Scan phase 2 did not reach its held gate")
        expectText(reading)
        await scanner.finish(2, failed: true)
        await #expect(throws: CocoaError.self) { try await failing.value }
        #expect(c.completedImageCount == nil && c.failure != nil)
        expectText("")
    } teardown: {
        c.end(); await scanner.finishAll()
    }
}
