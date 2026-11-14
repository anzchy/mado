import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #692 fix r1 (opus L2): the strip's 存储 is enabled whenever ⌘S is, including while the first text is typed.

@MainActor @Suite(.serialized) struct Issue692StripSaveTests {
    @Test(.timeLimit(.minutes(3))) func issue692StripSaveFollowsPendingText() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        let save = try context.strip().button(.save)
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        #expect(!controller.canSaveAnnotatedCopyFromMenu && !save.isEnabled, "an empty field saves nothing")
        try context.type("Hi")
        #expect(controller.canSaveAnnotatedCopyFromMenu)
        #expect(save.isEnabled, "存储 follows ⌘S while typing")
        try context.backspace()
        try context.backspace()
        #expect(!controller.canSaveAnnotatedCopyFromMenu)
        #expect(!save.isEnabled, "and goes off again when the text is emptied")
    }
}
