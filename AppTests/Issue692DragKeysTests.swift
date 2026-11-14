import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #692 fix r1 (opus M3): while a move or resize is held, ⌫/⌦, the arrows, ⌘Z/⇧⌘Z and Edit › Undo/Redo leave the
// marks alone (and the menu items are disabled), so mouse-up writes the moved mark into the right place and never
// resurrects a deleted one or overwrites another.

@MainActor private func menuEnabled(_ controller: CanvasWindowController, _ action: Selector) -> Bool {
    controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
}

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}

@MainActor @Suite(.serialized) struct Issue692DragKeysTests {
    /// Rectangles A (400,200)→(500,300) and B (600,400)→(700,500); C added and undone, so redo is available.
    private func setUp(_ context: Issue690Context) throws -> [AnnotationMark] {
        context.controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 700, y: 500))
        try context.drag(from: CGPoint(x: 800, y: 600), to: CGPoint(x: 850, y: 650))
        context.controller.undo(nil)
        try context.key("v", code: 9)
        try context.click(CGPoint(x: 450, y: 250))
        return context.marks()
    }

    /// Every mark-changing key and menu path, during the held drag.
    private func pressEverything(_ context: Issue690Context) throws {
        try context.backspace()
        try context.forwardDelete()
        try context.arrows()
        try context.key("z", code: 6, modifiers: [.command])
        try context.key("z", code: 6, modifiers: [.command, .shift])
        context.controller.undo(nil)
        context.controller.redo(nil)
    }

    @Test(.timeLimit(.minutes(3))) func issue692KeysDuringAHeldMoveChangeNothing() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let before = try setUp(context)
        let a = try #require(before.first), b = try #require(before.dropFirst().first)
        #expect(before.count == 2 && controller.session.annotateMode?.selectedMark == 0)
        #expect(menuEnabled(controller, #selector(CanvasWindowController.undo(_:))))
        #expect(menuEnabled(controller, #selector(CanvasWindowController.redo(_:))))

        try context.press(CGPoint(x: 450, y: 250), to: CGPoint(x: 480, y: 290))
        #expect(!menuEnabled(controller, #selector(CanvasWindowController.undo(_:))), "Undo is disabled while dragging")
        #expect(!menuEnabled(controller, #selector(CanvasWindowController.redo(_:))), "Redo is disabled while dragging")
        try pressEverything(context)
        #expect(context.marks() == before, "no key changed the marks during the drag")
        try context.release(CGPoint(x: 480, y: 290))

        let size = controller.canvas.backdropFrame.sourceSize
        let moved = AnnotationGeometry.translate(a, by: CGVector(dx: 30 / 0.32, dy: 40 / 0.32), imageSize: size)
        #expect(context.marks().count == 2)
        #expect(context.marks().first.map { near($0.rect, moved.rect) } == true, "A moved: \(context.marks())")
        #expect(context.marks().last == b, "B is untouched, not overwritten by a stale A")
        controller.undo(nil)
        #expect(context.marks() == before, "one undo takes back the move")
        #expect(menuEnabled(controller, #selector(CanvasWindowController.undo(_:))), "Undo is back after the drag")
    }

    @Test(.timeLimit(.minutes(3))) func issue692KeysDuringAHeldResizeChangeNothing() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let before = try setUp(context)
        let a = try #require(before.first), b = try #require(before.dropFirst().first)
        // A's bottom-right handle sits at view (500, 300).
        try context.press(CGPoint(x: 500, y: 300), to: CGPoint(x: 540, y: 340))
        try pressEverything(context)
        #expect(context.marks() == before, "no key changed the marks during the resize")
        try context.release(CGPoint(x: 540, y: 340))
        #expect(context.marks().count == 2)
        #expect(context.marks().last == b, "B is untouched")
        #expect(context.marks().first.map { $0.rect.width > a.rect.width } == true, "A grew")
    }
}
