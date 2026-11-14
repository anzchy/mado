import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #692 (P7-11) WI-1: the new tools in the Session and the document — deleting, moving, editing text, step numbering
// through undo, and the tool letters (grilling 5.5) and ⌫/⌦ in the key policy.

@MainActor private final class ToolsHost: AnnotateSaveHost {
    var hasImage = true
    var saves: [AnnotateSaveRequest] = []
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() {}
    func performAnnotatedCopySave(_ request: AnnotateSaveRequest) { saves.append(request) }
}

@MainActor private var keepAlive: [AnyObject] = []

/// A shown folder image, in Annotate Mode.
@MainActor private func annotating() async -> (ViewerSession, ToolsHost) {
    let host = ToolsHost(), loadHost = LoadHost()
    let session = ViewerSession(host: host)
    session.imageLoader.host = loadHost
    let ids = sessionItems()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    session.select(ids[1])
    CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.preview, from: .key, to: session)
    let url = URL(fileURLWithPath: "/photos/photo.jpg")
    session.openImage(url, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(url), access: LoadLeases(), pipeline: LoadPipeline())
    }
    await session.imageLoader.loadTask?.value
    keepAlive += [host, loadHost]
    session.enterAnnotateMode()
    return (session, host)
}

private let image = CGSize(width: 1600, height: 2400)
private func step(_ x: CGFloat) -> AnnotationMark { .step(centre: CGPoint(x: x, y: 100)) }
/// The mark at `i`, or a zero rectangle when there is none (no trap on a short array).
@MainActor private func markAt(_ session: ViewerSession, _ i: Int) -> AnnotationMark {
    marks(session).indices.contains(i) ? marks(session)[i] : AnnotationMark(rect: .zero)
}
@MainActor private func marks(_ session: ViewerSession) -> [AnnotationMark] { session.annotateMode?.document.marks ?? [] }

// MARK: - Document (D1–D3)

@Test(.timeLimit(.minutes(2))) func issue692DocumentRemoveIsUndoable() {
    var document = AnnotationDocument()
    let a = AnnotationMark(rect: CGRect(x: 0, y: 0, width: 5, height: 5)), b = step(50), c = step(90)
    for mark in [a, b, c] { document.add(mark) }
    let before = document.revision
    let removed = document.remove(at: 1)
    #expect(removed)
    #expect(document.marks == [a, c])
    #expect(document.revision != before && document.hasUnsavedMarks)
    let undone = document.undo()
    #expect(undone && document.marks == [a, b, c] && document.revision == before)
    let redone = document.redo()
    #expect(redone && document.marks == [a, c])
    #expect(!document.canRedo)
    // Out of range: nothing changes and no history entry is made.
    let revision = document.revision
    let outside = document.remove(at: 5), negative = document.remove(at: -1)
    #expect(!outside && !negative)
    #expect(document.revision == revision && document.marks == [a, c])
    let undoneAgain = document.undo()
    #expect(undoneAgain && document.marks == [a, b, c], "the last undo step is still the removal")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692DeletingAStepRenumbersAndUndoRestores() async {
    let (session, _) = await annotating()
    for x in [100.0, 200, 300] { session.addAnnotationMark(step(x)) }
    #expect(AnnotationGeometry.stepNumbers(marks(session)) == [1, 2, 3])
    session.selectAnnotationMark(1)
    #expect(session.deleteSelectedAnnotation())
    #expect(marks(session) == [step(100), step(300)])
    #expect(AnnotationGeometry.stepNumbers(marks(session)) == [1, 2], "the third marker is now 2")
    #expect(session.annotateMode?.selectedMark == nil)
    #expect(session.undoAnnotation())
    #expect(marks(session) == [step(100), step(200), step(300)])
    #expect(AnnotationGeometry.stepNumbers(marks(session)) == [1, 2, 3])
    #expect(session.redoAnnotation())
    // D3: a new marker takes the next number; there is no insertion.
    session.addAnnotationMark(step(400))
    #expect(AnnotationGeometry.stepNumbers(marks(session)) == [1, 2, 3])
    #expect(marks(session).last == step(400))
}

// MARK: - Session (S1–S7)

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ToolsSelectOnlyWhileAnnotating() async {
    let (session, _) = await annotating()
    for tool in [AnnotateTool.arrow, .text, .highlighter, .pen, .step, .select, .rectangle] {
        session.selectAnnotateTool(tool)
        #expect(session.annotateMode?.tool == tool)
    }
    #expect(session.requestLeaveAnnotateMode(.escape) == .proceed)
    session.selectAnnotateTool(.arrow)
    #expect(session.annotateMode == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692DeleteNeedsASelection() async {
    let (session, _) = await annotating()
    #expect(!session.deleteSelectedAnnotation())
    session.addAnnotationMark(step(100))
    session.selectAnnotationMark(nil)
    let revision = session.annotateMode?.document.revision
    #expect(!session.deleteSelectedAnnotation())
    #expect(session.annotateMode?.document.revision == revision && marks(session).count == 1)
    session.selectAnnotationMark(0)
    #expect(session.deleteSelectedAnnotation())
    #expect(marks(session).isEmpty && session.annotateMode?.selectedMark == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ReplaceIsOneUndoStepInPlace() async {
    let (session, _) = await annotating()
    for x in [100.0, 200, 300] { session.addAnnotationMark(step(x)) }
    let moved = AnnotationGeometry.translate(step(100), by: CGVector(dx: 10, dy: 0), imageSize: image)
    #expect(session.replaceAnnotationMark(at: 0, with: moved))
    // S3b: in place — the order, and so the numbers, are kept.
    #expect(marks(session) == [moved, step(200), step(300)])
    #expect(AnnotationGeometry.stepNumbers(marks(session)) == [1, 2, 3])
    #expect(session.annotateMode?.selectedMark == 0)
    #expect(session.undoAnnotation())
    #expect(marks(session) == [step(100), step(200), step(300)])
    // An unchanged mark or an index outside the marks makes no history entry.
    let revision = session.annotateMode?.document.revision
    #expect(!session.replaceAnnotationMark(at: 1, with: step(200)))
    #expect(!session.replaceAnnotationMark(at: 7, with: moved))
    #expect(session.annotateMode?.document.revision == revision)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692NudgeMovesEveryKind() async {
    let (session, _) = await annotating()
    let unit = AnnotationStyle.default
    let kinds: [AnnotationMark] = [
        .arrow(tail: CGPoint(x: 10, y: 10), tip: CGPoint(x: 50, y: 40), style: unit),
        .stroke(.pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 60)], style: unit),
        .stroke(.highlighter, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 60)], style: unit),
        .step(centre: CGPoint(x: 100, y: 100), style: unit),
        .text("Hi", origin: CGPoint(x: 20, y: 20), size: CGSize(width: 30, height: 22), style: unit),
    ]
    for mark in kinds {
        session.addAnnotationMark(mark)
        let index = marks(session).count - 1
        #expect(session.nudgeSelectedAnnotation(dx: 10, dy: 0, imageSize: image))
        #expect(markAt(session, index) == AnnotationGeometry.translate(mark, by: CGVector(dx: 10, dy: 0), imageSize: image),
                "\(mark.kind)")
        #expect(session.nudgeSelectedAnnotation(dx: 0, dy: -1, imageSize: image))
        #expect(markAt(session, index).rect.minY == mark.rect.minY - 1, "\(mark.kind) up")
    }
    // Clamped at the edge: no change, no history entry.
    session.addAnnotationMark(.step(centre: CGPoint(x: 14, y: 14), style: unit))
    #expect(!session.nudgeSelectedAnnotation(dx: -10, dy: 0, imageSize: image))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692CommitTextAddsEditsAndDeletes() async {
    let (session, _) = await annotating()
    let style = AnnotationStyle.forScreen(pointsPerImagePixel: 0.5)
    #expect(!session.commitAnnotationText("", at: CGPoint(x: 10, y: 10), editing: nil, style: style))
    #expect(!session.commitAnnotationText("  \n", at: CGPoint(x: 10, y: 10), editing: nil, style: style))
    #expect(marks(session).isEmpty && session.annotateMode?.document.canUndo == false)
    #expect(session.commitAnnotationText("从这里上岸", at: CGPoint(x: 10, y: 20), editing: nil, style: style))
    let mark = markAt(session, 0)
    #expect(mark.kind == .text && mark.text == "从这里上岸" && mark.points == [CGPoint(x: 10, y: 20)])
    let size = AnnotationRenderer.textSize("从这里上岸", fontSize: AnnotationMetrics.textFontSize * style.unit)
    #expect(mark.rect == CGRect(origin: CGPoint(x: 10, y: 20), size: size) && size.width > 0)
    #expect(session.annotateMode?.selectedMark == 0)
    // Editing keeps the origin and style and re-measures.
    #expect(session.commitAnnotationText("上岸", at: CGPoint(x: 99, y: 99), editing: 0, style: .default))
    let edited = markAt(session, 0)
    #expect(edited.text == "上岸" && edited.points == [CGPoint(x: 10, y: 20)] && edited.style == style)
    #expect(edited.rect.width < mark.rect.width)
    #expect(!session.commitAnnotationText("上岸", at: .zero, editing: 0, style: style), "unchanged text: no change")
    // Emptying an existing mark deletes it, undoably.
    #expect(session.commitAnnotationText("", at: .zero, editing: 0, style: style))
    #expect(marks(session).isEmpty)
    #expect(session.undoAnnotation() && marks(session) == [edited])
    #expect(!session.commitAnnotationText("x", at: .zero, editing: 4, style: style), "an index outside the marks")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692MovingOnlyAfterSavingIsUnsaved() async throws {
    let (session, host) = await annotating()
    session.addAnnotationMark(step(100))
    #expect(session.saveAnnotatedCopy())
    session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/photos/photo-annotated.jpg")))
    #expect(session.annotateMode?.needsPrompt == false)
    #expect(session.replaceAnnotationMark(at: 0, with: step(140)))
    #expect(session.annotateMode?.document.hasUnsavedMarks == true && session.annotateMode?.needsPrompt == true)
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
    #expect(host.saves.count == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692ReenteringStartsAgain() async {
    let (session, _) = await annotating()
    session.selectAnnotateTool(.step)
    session.addAnnotationMark(step(100))
    #expect(session.resolveAnnotatePrompt(.discard) == .refused, "no prompt is pending")
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask)
    #expect(session.resolveAnnotatePrompt(.discard) == .proceed)
    session.enterAnnotateMode()
    #expect(marks(session).isEmpty && session.annotateMode?.tool == .rectangle)
    session.addAnnotationMark(step(50))
    #expect(AnnotationGeometry.stepNumbers(marks(session)) == [1])
}

// MARK: - Text measurement

@Test(.timeLimit(.minutes(2))) func issue692TextSizeFollowsTheFontSize() {
    let small = AnnotationRenderer.textSize("Hi", fontSize: 18)
    let large = AnnotationRenderer.textSize("Hi", fontSize: 36)
    #expect((21...24).contains(small.height), "18 pt line box: \(small)")
    #expect((42...48).contains(large.height), "\(large)")
    #expect(small.width > 10 && abs(large.width - 2 * small.width) < 1.5)
    #expect(AnnotationRenderer.textSize("Hii", fontSize: 18).width > small.width)
}

// MARK: - Key policy (K1–K3)

@Test(.timeLimit(.minutes(2))) func issue692ToolLettersOnlyInAnnotateModeAndNotWhileTyping() {
    let table: [(String, AnnotateKeyAction)] = [
        ("a", .chooseTool(.arrow)), ("t", .chooseTool(.text)), ("h", .chooseTool(.highlighter)),
        ("p", .chooseTool(.pen)), ("n", .chooseTool(.step)), ("v", .selectTool), ("r", .selectRectangle),
    ]
    for (letter, action) in table {
        for key in [letter, letter.uppercased()] {
            #expect(AnnotateKeyPolicy.action(key: .character(key), modifiers: [], active: true, typing: false) == action)
            #expect(AnnotateKeyPolicy.action(key: .character(key), modifiers: .shift, active: true, typing: false) == action)
            #expect(AnnotateKeyPolicy.action(key: .character(key), modifiers: [], active: false, typing: false) == nil)
            #expect(AnnotateKeyPolicy.action(key: .character(key), modifiers: [], active: true, typing: true) == nil)
            for modifier in [AnnotateKeyModifiers.command, .control, .option] {
                #expect(AnnotateKeyPolicy.action(key: .character(key), modifiers: modifier, active: true, typing: false) == nil,
                        "\(key) \(modifier)")
            }
        }
    }
    // Redaction (M) and crop (C) are #693's; their letters do nothing yet. Other letters too.
    for letter in ["m", "c", "M", "C", "b", "x", "1", ""] {
        #expect(AnnotateKeyPolicy.action(key: .character(letter), modifiers: [], active: true, typing: false) == nil, "\(letter)")
    }
}

@Test(.timeLimit(.minutes(2))) func issue692DeleteKeysDeleteTheSelection() {
    for key in [AnnotateKey.delete, .forwardDelete] {
        #expect(AnnotateKeyPolicy.action(key: key, modifiers: [], active: true, typing: false) == .deleteSelection)
        #expect(AnnotateKeyPolicy.action(key: key, modifiers: [], active: false, typing: false) == nil)
        #expect(AnnotateKeyPolicy.action(key: key, modifiers: [], active: true, typing: true) == nil)
        for modifier in [AnnotateKeyModifiers.command, .control, .option, .shift] {
            #expect(AnnotateKeyPolicy.action(key: key, modifiers: modifier, active: true, typing: false) == nil)
        }
    }
}
