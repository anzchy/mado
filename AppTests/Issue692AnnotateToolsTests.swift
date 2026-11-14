import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

// #692 (P7-11) WI-4: the tool letters, ⌫/⌦, nudging, text editing against shortcuts, Esc order, renumbering and
// saving, in the real window (the #690 harness: a 1600×2400 image at page 39's zoom 0.32, origin 352,16, whatever
// the host screen).

private let keyCodes: [(String, UInt16, AnnotateTool)] = [("a", 0, .arrow), ("t", 17, .text), ("h", 4, .highlighter),
    ("p", 35, .pen), ("n", 45, .step), ("v", 9, .select), ("r", 15, .rectangle)]

private let codes: [Character: UInt16] = ["a": 0, "b": 11, "c": 8, "d": 2, "h": 4, "i": 34, "n": 45, "p": 35,
                                          "t": 17, "x": 7, "H": 4, "P": 35, "T": 17]

private let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
private let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
private let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
private let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)

extension Issue690Context {
    func type(_ text: String) throws {
        for character in text {
            try key(String(character), code: codes[character] ?? 0,
                    modifiers: character.isUppercase ? [.shift] : [])
        }
    }
    func backspace() throws { try key("\u{7f}", code: 51) }
    func forwardDelete() throws { try key(String(UnicodeScalar(NSDeleteFunctionKey)!), code: 117, modifiers: [.function]) }
    func escape() throws { try key("\u{1b}", code: 53) }
    func arrows() throws {
        try key(left, code: 123, modifiers: [.numericPad, .function])
        try key(right, code: 124, modifiers: [.numericPad, .function])
        try key(downArrow, code: 125, modifiers: [.numericPad, .function])
        try key(upArrow, code: 126, modifiers: [.numericPad, .function])
    }
    func marks() -> [AnnotationMark] { controller.session.annotateMode?.document.marks ?? [] }
    /// A drag that is still held: mouse-down and one drag, no mouse-up.
    func press(_ a: CGPoint, to b: CGPoint) throws {
        let view = try overlay()
        view.mouseDown(with: try mouse(view, .leftMouseDown, a))
        view.mouseDragged(with: try mouse(view, .leftMouseDragged, b))
    }
    func release(_ point: CGPoint) throws {
        let view = try overlay()
        view.mouseUp(with: try mouse(view, .leftMouseUp, point))
    }
}

/// The marks at `indices`, or [] when any is missing (no trap on a red run).
private func pick(_ marks: [AnnotationMark], _ indices: Int...) -> [AnnotationMark] {
    indices.allSatisfy(marks.indices.contains) ? indices.map { marks[$0] } : []
}

/// Page 39: view (x, y) is image ((x − 352) / 0.32, (y − 16) / 0.32).
private func image(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 352) / 0.32, y: (y - 16) / 0.32) }

@MainActor @Suite(.serialized) struct Issue692AnnotateToolsTests {
    @Test(.timeLimit(.minutes(3))) func issue692LettersChooseToolsOnlyInAnnotateMode() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let zoom = controller.canvas.backdropFrame.transform.zoom
        for (character, code, _) in keyCodes { try context.key(character, code: code) }
        try context.backspace()
        try context.forwardDelete()
        try await context.settle()
        #expect(!controller.session.isAnnotating, "no letter starts Annotate Mode")
        #expect(controller.session.imageLoader.fileURL == context.first)
        #expect(controller.canvas.backdropFrame.transform.zoom == zoom)
        #expect(controller.session.isEnabled(.next), "browsing is untouched")

        controller.enterAnnotateMode()
        let strip = try context.strip()
        let items: [AnnotateTool: AnnotateStripItem] = [.arrow: .arrow, .text: .text, .highlighter: .highlighter,
            .pen: .pen, .step: .step, .select: .select, .rectangle: .rectangle]
        for (character, code, tool) in keyCodes {
            try context.key(character, code: code)
            #expect(controller.session.annotateMode?.tool == tool, "\(character)")
            #expect(strip.button(try #require(items[tool])).state == .on, "\(character) presses its button")
            #expect(try context.overlay().tool == tool)
        }
        // Shift gives the same tool; ⌘/⌥/⌃ letters are not tool keys.
        try context.key("A", code: 0, modifiers: [.shift])
        #expect(controller.session.annotateMode?.tool == .arrow)
        try context.key("t", code: 17, modifiers: [.option])
        try context.key("h", code: 4, modifiers: [.control])
        #expect(controller.session.annotateMode?.tool == .arrow)
        #expect(controller.session.imageLoader.fileURL == context.first)
    }

    @Test(.timeLimit(.minutes(3))) func issue692TypingGoesToTheTextNotTheShortcuts() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.ui.answer = .cancel
        // A selected text mark "x" exists while a new one is typed.
        controller.session.commitAnnotationText("x", at: image(400, 100), editing: nil, style: .forScreen(pointsPerImagePixel: 0.32))
        let x = try #require(context.marks().first)
        #expect(controller.session.annotateMode?.selectedMark == 0)
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        let overlay = try context.overlay()
        #expect(overlay.isEditingText)
        #expect(controller.focusContext == .textInput)
        // Edit › Undo while typing belongs to the text: the selected mark "x" stays.
        _ = controller.window?.firstResponder?.tryToPerform(#selector(CanvasWindowController.undo(_:)), with: nil)
        #expect(context.marks() == [x])
        try context.type("aThPn")
        try context.backspace()
        try context.arrows()
        let field = try #require(overlay.textEditor)
        #expect(field.stringValue == "aThP", "every key went to the field: \(field.stringValue)")
        #expect(controller.session.annotateMode?.tool == .text)
        #expect(controller.session.imageLoader.fileURL == context.first)
        #expect(context.marks() == [x], "⌫, the arrows and ⌘Z never touched the selected mark")
        #expect(controller.session.annotateMode?.document.marks.count == 1)
        // Esc ends the typing first, still annotating, nothing asked.
        try context.escape()
        #expect(!overlay.isEditingText)
        #expect(controller.session.isAnnotating && context.ui.asked.isEmpty)
        #expect(context.marks().count == 2)
        #expect(context.marks().last?.kind == .text && context.marks().last?.text == "aThP")
        #expect(controller.focusContext == .canvas, "the canvas has the keys again")
        // A second Esc asks about the unsaved marks.
        try context.escape()
        #expect(context.ui.asked == [.escape])
        #expect(controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue692EscapeDuringADragCancelsOnlyTheDrag() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.ui.answer = .cancel
        try context.key("a", code: 0)
        try context.press(CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.escape()
        try context.release(CGPoint(x: 500, y: 300))
        #expect(context.marks().isEmpty, "the arrow was dropped")
        #expect(controller.session.isAnnotating && context.ui.asked.isEmpty)

        // Esc during a move keeps the mark, the selection, the tool and the history.
        try context.key("r", code: 15)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("v", code: 9)
        let before = context.marks()
        let undo = controller.session.annotateMode?.document.canUndo
        let selection = controller.session.annotateMode?.selectedMark
        try context.press(CGPoint(x: 450, y: 200), to: CGPoint(x: 480, y: 240))
        try context.escape()
        try context.release(CGPoint(x: 480, y: 240))
        #expect(context.marks() == before)
        #expect(controller.session.annotateMode?.selectedMark == selection)
        #expect(controller.session.annotateMode?.document.canUndo == undo)
        #expect(controller.session.annotateMode?.tool == .select)
        #expect(controller.session.isAnnotating && context.ui.asked.isEmpty)
        controller.undo(nil)
        #expect(context.marks().isEmpty, "one undo removes the rectangle: the cancelled move left no history")
    }

    @Test(.timeLimit(.minutes(3))) func issue692DeleteUndoRedoAndRenumber() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("n", code: 45)
        for x in [450.0, 550, 650] { try context.click(CGPoint(x: x, y: 400)) }
        #expect(AnnotationGeometry.stepNumbers(context.marks()) == [1, 2, 3])
        let three = context.marks()
        try context.key("v", code: 9)
        try context.click(CGPoint(x: 550, y: 400))
        #expect(controller.session.annotateMode?.selectedMark == 1)
        try context.backspace()
        #expect(context.marks() == pick(three, 0, 2))
        #expect(AnnotationGeometry.stepNumbers(context.marks()) == [1, 2], "the third marker is now 2")
        #expect(controller.session.annotateMode?.selectedMark == nil)
        controller.undo(nil)
        #expect(context.marks() == three, "undo brings the second marker back as 2")
        controller.redo(nil)
        #expect(context.marks() == pick(three, 0, 2))
        // ⌫ and ⌦ without a selection are consumed and change nothing.
        try context.backspace()
        try context.forwardDelete()
        try await context.settle()
        #expect(context.marks() == pick(three, 0, 2))
        #expect(controller.session.imageLoader.fileURL == context.first && controller.session.isAnnotating)
        // ⌦ deletes a selection too; a new marker takes the next number.
        try context.click(CGPoint(x: 450, y: 400))
        try context.forwardDelete()
        #expect(context.marks() == pick(three, 2))
        try context.key("n", code: 45)
        try context.click(CGPoint(x: 700, y: 600))
        #expect(AnnotationGeometry.stepNumbers(context.marks()) == [1, 2])
    }

    @Test(.timeLimit(.minutes(3))) func issue692ArrowKeysNudgeAndNeverChangeImages() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.arrows()
        try context.arrows()
        try await context.settle()
        #expect(controller.session.imageLoader.fileURL == context.first, "no selection: the image stays")
        #expect(controller.session.isAnnotating)
        try context.key("a", code: 0)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let arrow = try #require(context.marks().first)
        let tail = try #require(arrow.points.first)
        let steps: [(String, UInt16, CGFloat, CGFloat)] = [(upArrow, 126, 0, -1), (upArrow, 126, 0, -2),
            (right, 124, 1, -2), (downArrow, 125, 1, -1), (left, 123, 0, -1)]
        for (characters, code, dx, dy) in steps {
            try context.key(characters, code: code, modifiers: [.numericPad, .function])
            let now = context.marks().first?.points.first
            #expect(now == CGPoint(x: tail.x + dx, y: tail.y + dy), "key \(code): \(String(describing: now)) from \(tail)")
        }
        #expect(context.marks().first?.points.map { CGPoint(x: $0.x, y: $0.y + 1) } == arrow.points, "the whole arrow moved")
        try await context.settle()
        #expect(controller.session.imageLoader.fileURL == context.first)
        controller.undo(nil)
        #expect(context.marks().first?.points.first == CGPoint(x: tail.x + 1, y: tail.y - 1), "each nudge undoes")
    }

    @Test(.timeLimit(.minutes(3))) func issue692SaveWhileTypingWritesTheText() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        try context.type("Hi")
        #expect(controller.canSaveAnnotatedCopyFromMenu, "⌘S is available while the first text is typed")
        try context.perform("annotate.save.menu")
        #expect(try !context.overlay().isEditingText)
        let text = try #require(context.marks().first)
        #expect(text.kind == .text && text.text == "Hi")
        try await waitUntil("copy saved", timeout: .seconds(60)) { context.ui.saved.count == 1 }
        let copy = try issue690Image(try #require(context.ui.saved.first))
        var red = 0
        for y in stride(from: Int(text.rect.minY), to: Int(text.rect.maxY), by: 2) {
            for x in stride(from: Int(text.rect.minX), to: Int(text.rect.maxX), by: 2) {
                let p = try issue690Pixel(copy, x: x, y: y)
                if p[0] > 180 && p[1] < 90 && p[2] < 90 { red += 1 }
            }
        }
        #expect(red > 20, "the copy has the red text: \(red)")
    }

    @Test(.timeLimit(.minutes(3))) func issue692AfterSavingAClickLeavesButAMoveAsks() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.ui.answer = .cancel
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        controller.saveAnnotatedCopy()
        try await waitUntil("saved", timeout: .seconds(60)) { context.ui.saved.count == 1 }
        try context.key("v", code: 9)
        try context.click(CGPoint(x: 450, y: 200))
        try context.escape()
        #expect(!controller.session.isAnnotating && context.ui.asked.isEmpty, "a click changes nothing")

        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        controller.saveAnnotatedCopy()
        try await waitUntil("saved again", timeout: .seconds(60)) { context.ui.saved.count == 2 }
        try context.key("v", code: 9)
        try context.drag(from: CGPoint(x: 450, y: 200), to: CGPoint(x: 470, y: 220))
        try context.escape()
        #expect(context.ui.asked == [.escape], "a moved mark is unsaved")
        #expect(controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue692LeavingAndReenteringStartsFresh() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("n", code: 45)
        try context.click(CGPoint(x: 500, y: 400))
        try context.click(CGPoint(x: 600, y: 400))
        context.ui.answer = .discard
        try context.escape()
        #expect(!controller.session.isAnnotating)
        controller.enterAnnotateMode()
        #expect(context.marks().isEmpty)
        #expect(controller.session.annotateMode?.tool == .rectangle)
        try context.key("n", code: 45)
        try context.click(CGPoint(x: 500, y: 400))
        #expect(AnnotationGeometry.stepNumbers(context.marks()) == [1])
    }

    @Test(.timeLimit(.minutes(3))) func issue692StripToolChangeAndCloseCommitTheText() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        try context.type("ab")
        try context.strip().button(.arrow).performClick(nil)
        #expect(context.marks().map(\.text) == ["ab"])
        #expect(controller.session.annotateMode?.tool == .arrow)
        #expect(try !context.overlay().isEditingText)

        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 600))
        try context.type("cd")
        context.ui.answer = .cancel
        #expect(!controller.windowShouldClose(try #require(controller.window)))
        #expect(context.marks().map(\.text) == ["ab", "cd"], "⌘W commits the text before asking")
        #expect(context.ui.asked == [.closeWindow])
    }

    @Test(.timeLimit(.minutes(3))) func issue692ToolLabelsInChineseAndEnglish() async throws {
        let expected = [("Arrow", "箭头"), ("Text", "文字"), ("Highlighter", "荧光笔"), ("Pen", "画笔"), ("Step", "序号"),
                        ("Annotation Text", "标注文字")]
        for (key, chinese) in expected {
            #expect(try issue690CatalogValue(key, "en") == key)
            #expect(try issue690CatalogValue(key, "zh-Hans") == chinese)
        }
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        let strip = try context.strip()
        for item: AnnotateStripItem in [.arrow, .text, .highlighter, .pen, .step] {
            #expect(strip.button(item).accessibilityLabel()?.isEmpty == false, "\(item)")
        }
        try context.key("t", code: 17)
        try context.click(CGPoint(x: 600, y: 400))
        #expect(try context.overlay().textEditor?.accessibilityLabel() == String(localized: "Annotation Text"))
    }
}
