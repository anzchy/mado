import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #692 fix r1 (gpt F1, opus M4): in the real window a VoiceOver user selects a mark through accessibility and deletes
// it with the 删除 action, undoably; the remaining steps renumber. Labels are in Chinese and English.

@MainActor private func markElements(_ overlay: AnnotationOverlayView) -> [NSAccessibilityElement] {
    (overlay.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
}

@MainActor @Suite(.serialized) struct Issue692MarkAccessibilityTests {
    @Test(.timeLimit(.minutes(3))) func issue692AccessibilitySelectAndDeleteAMark() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("n", code: 45)
        for x in [450.0, 550, 650] { try context.click(CGPoint(x: x, y: 400)) }
        let three = context.marks()
        let overlay = try context.overlay()
        let step = String(localized: "Step %lld")
        #expect(markElements(overlay).map { $0.accessibilityLabel() ?? "" }
                == [1, 2, 3].map { String(format: step, $0) })
        controller.session.selectAnnotationMark(nil)
        controller.syncAnnotateUI()

        let second = try #require(markElements(overlay).dropFirst().first)
        second.setAccessibilitySelected(true)
        #expect(controller.session.annotateMode?.selectedMark == 1, "accessibility selects the mark")
        #expect(second.isAccessibilitySelected())

        let delete = try #require(second.accessibilityCustomActions()?.first)
        #expect(delete.name == String(localized: "Delete"))
        #expect(delete.handler?() == true)
        #expect(context.marks().count == 2 && context.marks().first == three.first && context.marks().last == three.last)
        #expect(markElements(overlay).map { $0.accessibilityLabel() ?? "" } == [1, 2].map { String(format: step, $0) },
                "the third marker now reads 2")
        controller.undo(nil)
        #expect(context.marks() == three, "the delete undoes")
        #expect(markElements(overlay).count == 3)
    }

    @Test(.timeLimit(.minutes(1))) func issue692MarkAccessibilityStringsInChineseAndEnglish() throws {
        let expected = [("Step %lld", "Step %lld", "序号 %lld"), ("Delete", "Delete", "删除"),
                        ("Annotations", "Annotations", "标注")]
        for (key, english, chinese) in expected {
            #expect(try issue690CatalogValue(key, "en") == english)
            #expect(try issue690CatalogValue(key, "zh-Hans") == chinese)
        }
    }
}
