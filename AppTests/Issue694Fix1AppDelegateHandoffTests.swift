import AppKit
import Testing
import MadoApplication

// i694-fix1 (audit opus M2): the AppDelegate glue. A Launch Services open (application(_:open:)) reads the injected
// hand-off store: a fresh record naming the opened file enters Annotate Mode; no record opens plainly.

private func fixture694Fix1() throws -> (dir: URL, file: URL) {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("mado-20261122090000.png")
    try fm.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png"), to: file)
    return (dir, file)
}

@MainActor private func openedController694Fix1(_ delegate: AppDelegate, _ file: URL) throws -> CanvasWindowController {
    let existing = Set(NSApplication.shared.windows.map(\.windowNumber))
    delegate.application(NSApplication.shared, open: [file])
    let window = try #require(NSApplication.shared.windows.first {
        !existing.contains($0.windowNumber) && $0.windowController is CanvasWindowController })
    return try #require(window.windowController as? CanvasWindowController)
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct Issue694Fix1AppDelegateHandoffTests {
    @Test func issue694Fix1DelegateOpenWithRecordEntersAnnotateMode() async throws {
        let (dir, file) = try fixture694Fix1()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handoff = Handoff694App()
        handoff.write(CaptureAnnotateHandoffRecord(fileURL: file, createdAt: Date()))
        let controller = try openedController694Fix1(AppDelegate(annotateHandoff: handoff), file)
        defer { controller.window?.close() }
        try await waitUntil("the Capture shown in Annotate Mode", timeout: .seconds(60)) {
            controller.session.isAnnotating
        }
        #expect(controller.session.annotateMode?.fileURL?.lastPathComponent == file.lastPathComponent)
        #expect(handoff.calls.contains("take"))
        #expect(handoff.record == nil, "the record is consumed")
    }

    @Test func issue694Fix1DelegateOpenWithoutRecordOnlyViews() async throws {
        let (dir, file) = try fixture694Fix1()
        defer { try? FileManager.default.removeItem(at: dir) }
        let handoff = Handoff694App()
        let controller = try openedController694Fix1(AppDelegate(annotateHandoff: handoff), file)
        defer { controller.window?.close() }
        try await waitUntil("the Capture shown", timeout: .seconds(60)) {
            controller.session.imageStatus == .showing
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!controller.session.isAnnotating)
        #expect(controller.session.annotateOnShow == nil)
        #expect(handoff.calls == ["take"])
    }
}
