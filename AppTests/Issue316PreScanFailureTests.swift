import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private final class Issue316MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor private func issue316State(_ controller: CanvasWindowController) throws -> ViewerStateHost {
    try #require(controller.window?.contentView?.subviews.compactMap { $0 as? ViewerStateHost }.first)
}

/// Both pre-scan error policies must leave the reading surface before their sheet can be declined.
@Test(.timeLimit(.minutes(3)), arguments: [FileAccessError.corruptStore, .startFailed])
@MainActor func i316PreScanFailureRestoresHome(error: FileAccessError) async throws {
    _ = NSApplication.shared
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { throw error },
        motionPolicy: MotionPolicy(source: Issue316MotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let state = try issue316State(controller)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("i316-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    controller.browseRecoveredFolder(folder, rootID: AccessRootID())
    #expect(state.surface == .gridReading)
    #expect(state.textLines.first == "Reading Folder…")
    state.refresh()
    #expect(!state.buttons.contains { $0.identifier?.rawValue == "state.open" }, "no transient Home in the pre-scan gap")
    try await waitUntil { window.attachedSheet != nil }
    let sheet = try #require(window.attachedSheet)
    #expect(state.surface == .viewer, "a completed pre-scan error must stop claiming to read")
    #expect(state.buttons.contains { $0.identifier?.rawValue == "state.open" })
    #expect(!state.buttons.contains { $0.identifier?.rawValue == "state.cancel-folder" })
    window.endSheet(sheet, returnCode: error == .corruptStore ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    try await waitUntil { window.attachedSheet == nil }
    state.refresh()
    #expect(state.surface == .viewer)
    #expect(state.buttons.contains { $0.identifier?.rawValue == "state.open" }, "declining recovery leaves the restored Home")
}

/// The same restore point used by Cancel Reading preserves a prior error viewer, not always Home.
@Test(.timeLimit(.minutes(3))) @MainActor func i316PreScanFailureRestoresPriorErrorViewer() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("i316-viewer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("prior.png")
    try Data().write(to: image)
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { throw FileAccessError.startFailed },
        motionPolicy: MotionPolicy(source: Issue316MotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let state = try issue316State(controller)
    controller.open(image)
    try await waitUntil {
        if case .failed = controller.session.imageStatus { return true }
        return false
    }
    // The prior image's access error has its own sheet. Retire it so the next sheet proves the folder task exited.
    try await waitUntil { window.attachedSheet != nil }
    let priorSheet = try #require(window.attachedSheet)
    window.endSheet(priorSheet, returnCode: .alertFirstButtonReturn)
    try await waitUntil { window.attachedSheet == nil }
    state.refresh()
    let priorText = state.textLines
    #expect(controller.session.imageLoader.fileURL == image)
    controller.browseRecoveredFolder(folder, rootID: AccessRootID())
    #expect(state.surface == .gridReading)
    try await waitUntil { window.attachedSheet != nil }
    let sheet = try #require(window.attachedSheet)
    #expect(state.surface == .viewer)
    #expect(controller.session.imageLoader.fileURL == image)
    #expect(!state.buttons.contains { $0.identifier?.rawValue == "state.open" })
    #expect(!state.buttons.contains { $0.identifier?.rawValue == "state.cancel-folder" })
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    try await waitUntil { window.attachedSheet == nil }
    // Restoration reopens the same URL through the same unavailable service, so its prior error returns.
    // Do not wait for the expected restored surface: the old implementation must fail assertions, not hang.
    try await waitUntil {
        if case .failed = controller.session.imageStatus { return true }
        return controller.session.imageLoader.fileURL != image
    }
    state.refresh()
    #expect(state.surface == .viewer)
    #expect(controller.session.imageLoader.fileURL == image)
    #expect(state.textLines == priorText)
}
