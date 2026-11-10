import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] != "1"),
      .timeLimit(.minutes(3))) @MainActor
func issue527InspectorCanvasPressPassesInIsolatedProcess() async throws {
    try await issue521RunNativeTest(filter: "issue527InspectorCloseCanvasPressPans\\b",
        summary: "Test issue527InspectorCloseCanvasPressPans() passed")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] == "1"),
      .timeLimit(.minutes(3))) @MainActor
func issue527InspectorCloseCanvasPressPans() async throws {
    let scene = try Issue527Scene()
    defer { scene.close() }
    // Allow 15 s for key acquisition; the parent's shared 150 s deadline also covers swiftc.
    try await scene.open(keyWindowTimeout: .seconds(180) / 12)
    try #require(scene.controller.route(.inspector, from: .key))
    try await scene.wait {
        issue527Find(scene.window.contentView) { $0.accessibilityIdentifier() == "inspector.close" } != nil
    }
    let close = try #require(issue527Find(scene.window.contentView) {
        $0.accessibilityIdentifier() == "inspector.close"
    })
    let initial = try issue521Marker(scene.canvas)
    let file = scene.controller.session.imageLoader.fileURL
    for delta in [CGPoint(x: 40, y: 30), CGPoint(x: -40, y: -30)] {
        scene.controller.session.updateFocus(.panel)
        try #require(scene.window.makeFirstResponder(close))
        scene.layout()
        try #require(scene.window.firstResponder === close)
        try #require(scene.controller.session.inspectorFocus.focus == .panel)
        let canvasCentre = CGPoint(x: scene.canvas.bounds.midX, y: scene.canvas.bounds.midY)
        let centre = scene.canvas.convert(canvasCentre, to: nil)
        try #require(scene.hit(at: centre) === scene.canvas)
        let before = try issue521Marker(scene.canvas)
        try scene.mouse(.leftMouseDown, at: centre)
        #expect(scene.window.firstResponder === scene.canvas)
        #expect(scene.controller.session.inspectorFocus.focus == .canvas)
        let end = scene.canvas.convert(CGPoint(x: canvasCentre.x + delta.x, y: canvasCentre.y + delta.y), to: nil)
        try scene.mouse(.leftMouseDragged, at: end)
        try scene.mouse(.leftMouseUp, at: end)
        let after = try issue521Marker(scene.canvas)
        #expect(after.x - before.x == delta.x)
        #expect(after.y - before.y == delta.y)
        #expect(scene.window.firstResponder === scene.canvas)
        #expect(scene.controller.session.inspectorFocus.focus == .canvas)
        #expect(scene.controller.session.inspectorFocus.isVisible)
        #expect(scene.controller.session.mode == .viewing)
        #expect(scene.controller.session.imageLoader.fileURL == file)
    }
    #expect(try issue521Marker(scene.canvas) == initial)
}
