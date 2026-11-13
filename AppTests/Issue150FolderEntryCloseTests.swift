import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue150MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Closing the window ends a folder entry; a reused controller's Cancel Reading must not restore what was shown before.
@Test(.timeLimit(.minutes(3))) @MainActor func issue150ClosingWindowDropsFolderEntryRestorePoint() throws {
    _ = NSApplication.shared
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { throw CancellationError() },
        motionPolicy: MotionPolicy(source: Issue150MotionSource()))
    let window = try #require(controller.window)
    let shown = URL(fileURLWithPath: "/tmp/issue150-close/a.png")
    controller.session.beginFolderEntry(shownImage: shown, hasCompleteGrid: false)
    window.close()
    #expect(controller.session.cancelFolderEntry() == nil)
}

/// After a close the reused controller records a fresh folder entry: the new set is ended and comes back on Cancel.
@Test(.timeLimit(.minutes(3))) @MainActor func issue150ReusedWindowRecordsNewFolderEntryAfterClose() async throws {
    let scene = try await Issue150Scene()
    defer { scene.close() }
    try await scene.openFilePreviewSetAtMiddle()
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntilReading()
    scene.window.close()
    try await scene.openFilePreviewSetAtMiddle()
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntilReading()
    #expect(scene.controller.session.filePreviewSet == nil, "a stale restore closure would skip recording this entry")
    try await scene.cancelReading()
    scene.expectSetRestoredAtMiddle()
}

/// Closing during a reading, then entering a folder straight away: Cancel returns to what the reopened window showed
/// (nothing), not a stopped half-read grid. A restore closure kept across the close would skip recording this entry.
@Test(.timeLimit(.minutes(3))) @MainActor func issue150FolderEntryRightAfterCloseCancelsToEmptyState() async throws {
    let scene = try await Issue150Scene()
    defer { scene.close() }
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntilReading()
    scene.window.close()
    scene.controller.openGrantedFolder(scene.folder)
    try await scene.waitUntilReading()
    try await scene.cancelReading()
    #expect(scene.controller.session.mode == .viewing)
    #expect(scene.controller.session.folderScan?.isReadingFolder == false)
}
