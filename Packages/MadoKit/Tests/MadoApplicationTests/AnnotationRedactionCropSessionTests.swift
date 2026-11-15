import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #693 slice B (P7-11) WI-1: redaction styles and the crop in the document, the Session and the key policy
// (tests-20261114-i693b.md M4–M12). Brief §1: one undo step per create, move/resize, style change and delete; crop
// set, replace and clear.

@MainActor private final class CropHost: AnnotateSaveHost {
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

@MainActor private func annotating() async -> (ViewerSession, CropHost) {
    let host = CropHost(), loadHost = LoadHost()
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

private let a = CGRect(x: 10, y: 20, width: 300, height: 400)
private let b = CGRect(x: 50, y: 60, width: 100, height: 120)
private let c = CGRect(x: 0, y: 0, width: 800, height: 600)
private let box = CGRect(x: 100, y: 100, width: 64, height: 48)

@MainActor private func marks(_ session: ViewerSession) -> [AnnotationMark] { session.annotateMode?.document.marks ?? [] }
@MainActor private func crop(_ session: ViewerSession) -> CGRect? { session.annotateMode?.document.crop }

// MARK: - Document (M4–M6)

@Test(.timeLimit(.minutes(2))) func issue693CropIsOneUndoStepPerSetReplaceClear() {
    var document = AnnotationDocument()
    func set(_ rect: CGRect?) -> Bool { document.setCrop(rect) }
    func undo() -> Bool { document.undo() }
    func redo() -> Bool { document.redo() }
    #expect(document.crop == nil && !document.canUndo)
    #expect(set(a))
    #expect(document.crop == a && document.canUndo && document.hasUnsavedMarks)
    #expect(set(b))
    #expect(document.crop == b)
    #expect(set(nil))
    #expect(document.crop == nil)
    // The same crop again is no change and adds no step.
    #expect(!set(nil))
    #expect(undo() && document.crop == b)
    #expect(undo() && document.crop == a)
    #expect(undo() && document.crop == nil)
    #expect(!undo(), "exactly three steps")
    #expect(redo() && document.crop == a)
    #expect(redo() && document.crop == b)
    #expect(redo() && document.crop == nil)
    #expect(!redo())
    #expect(set(a) && !set(a))
    #expect(undo() && document.crop == nil, "setting the same crop twice is one step")
}

@Test(.timeLimit(.minutes(2))) func issue693UndoRestoresMarksAndCropTogether() {
    var document = AnnotationDocument()
    func undo() -> Bool { document.undo() }
    func redo() -> Bool { document.redo() }
    let first = AnnotationMark(rect: box), second = AnnotationMark.redaction(rect: b, style: .solid)
    document.add(first)
    document.setCrop(a)
    document.add(second)
    #expect(document.marks == [first, second] && document.crop == a)
    #expect(undo())
    #expect(document.marks == [first] && document.crop == a)
    #expect(undo())
    #expect(document.marks == [first] && document.crop == nil)
    #expect(redo() && redo())
    #expect(document.marks == [first, second] && document.crop == a)
    // A change after an undo drops the redo of the crop too.
    #expect(undo() && undo())
    document.add(second)
    #expect(!document.canRedo && document.crop == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693CropCountsForSaveAndPrompt() async {
    var document = AnnotationDocument()
    #expect(!document.canSave)
    document.setCrop(a)
    #expect(document.canSave, "a crop alone can be saved")
    let (session, host) = await annotating()
    #expect(session.annotateMode?.needsPrompt == false)
    session.selectAnnotateTool(.crop)
    session.setPendingCrop(a)
    #expect(session.applyPendingCrop())
    #expect(session.annotateMode?.needsPrompt == true, "an unsaved crop asks on leaving")
    #expect(session.canSaveAnnotatedCopy)
    #expect(session.saveAnnotatedCopy())
    session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/photos/photo-annotated.jpg")))
    #expect(session.annotateMode?.needsPrompt == false)
    #expect(session.clearCrop())
    #expect(session.annotateMode?.document.hasUnsavedMarks == true, "clearing a saved crop is a change")
    #expect(host.saves.count == 1)
}

// MARK: - Session (M7–M11)

@Test(.timeLimit(.minutes(2))) @MainActor func issue693NewRedactionGetsTheToolStyleAtLeastTheMinimum() async {
    let (session, _) = await annotating()
    #expect(session.annotateMode?.redactionStyle == .mosaic(strength: 24), "brief default")
    session.selectAnnotateTool(.redact)
    #expect(session.annotateMode?.tool == .redact)
    session.setRedactionStyle(.mosaic(strength: 4))
    #expect(session.annotateMode?.redactionStyle == .mosaic(strength: 16), "never below the measured minimum")
    session.addAnnotationMark(.redaction(rect: box, style: .solid))
    #expect(marks(session).last?.redaction == .mosaic(strength: 16), "a new redaction gets the tool's style")
    session.setRedactionStyle(.solid)
    session.selectAnnotationMark(nil)
    session.addAnnotationMark(.redaction(rect: b, style: .mosaic(strength: 40)))
    #expect(marks(session).last?.redaction == .solid)
    // Other kinds are added as they are.
    session.addAnnotationMark(AnnotationMark(rect: box))
    #expect(marks(session).last?.redaction == nil && marks(session).last?.kind == .rectangle)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693StyleChangeOnASelectedRedactionIsOneUndoStep() async {
    let (session, _) = await annotating()
    session.selectAnnotateTool(.redact)
    session.addAnnotationMark(.redaction(rect: box, style: .solid))
    #expect(marks(session).first?.redaction == .mosaic(strength: 24))
    #expect(session.setRedactionStyle(.solid), "the selected redaction changed")
    #expect(marks(session).first?.redaction == .solid)
    #expect(marks(session).first?.rect == box)
    #expect(session.annotateMode?.selectedMark == 0)
    #expect(!session.setRedactionStyle(.solid), "the same style again is no change")
    #expect(session.undoAnnotation())
    #expect(marks(session).first?.redaction == .mosaic(strength: 24))
    #expect(session.undoAnnotation())
    #expect(marks(session).isEmpty)
    #expect(!session.undoAnnotation(), "create and restyle are exactly two steps")
    #expect(session.redoAnnotation() && session.redoAnnotation())
    #expect(marks(session).first?.redaction == .solid)
    // The tool's style follows a restyle of the selected mark: the next redaction gets it.
    session.selectAnnotationMark(0)
    #expect(session.setRedactionStyle(.mosaic(strength: 30)))
    #expect(session.annotateMode?.redactionStyle == .mosaic(strength: 30))
    session.selectAnnotationMark(nil)
    session.addAnnotationMark(.redaction(rect: b, style: .solid))
    #expect(marks(session).last?.redaction == .mosaic(strength: 30))
    #expect(session.undoAnnotation())
    session.selectAnnotationMark(0)
    #expect(session.setRedactionStyle(.solid))
    // A strength below the minimum on the selected mark is raised too.
    session.selectAnnotationMark(0)
    #expect(session.setRedactionStyle(.mosaic(strength: 2)))
    #expect(marks(session).first?.redaction == .mosaic(strength: 16))
    // With a selected mark of another kind only the tool's style changes.
    session.addAnnotationMark(AnnotationMark(rect: b))
    let before = marks(session)
    #expect(!session.setRedactionStyle(.mosaic(strength: 50)))
    #expect(marks(session) == before)
    #expect(session.annotateMode?.redactionStyle == .mosaic(strength: 50))
    // Without a selection, likewise.
    session.selectAnnotationMark(nil)
    #expect(!session.setRedactionStyle(.solid))
    #expect(marks(session) == before)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693PendingCropAppliesOnceCancelsAndClears() async {
    let (session, _) = await annotating()
    session.selectAnnotateTool(.crop)
    #expect(!session.applyPendingCrop(), "nothing pending")
    #expect(!session.cancelPendingCrop())
    session.setPendingCrop(a)
    #expect(session.annotateMode?.pendingCrop == a)
    #expect(crop(session) == nil && session.annotateMode?.document.canUndo == false, "pending is not applied")
    #expect(session.applyPendingCrop())
    #expect(crop(session) == a && session.annotateMode?.pendingCrop == nil)
    #expect(session.annotateMode?.document.canUndo == true)
    // Replace, then cancel a pending one: the applied crop stays.
    session.setPendingCrop(b)
    #expect(session.cancelPendingCrop())
    #expect(crop(session) == a && session.annotateMode?.pendingCrop == nil)
    session.setPendingCrop(b)
    #expect(session.applyPendingCrop() && crop(session) == b)
    // Applying the crop already applied is no step.
    session.setPendingCrop(b)
    #expect(!session.applyPendingCrop())
    #expect(session.annotateMode?.pendingCrop == nil)
    #expect(session.clearCrop())
    #expect(crop(session) == nil)
    #expect(!session.clearCrop(), "nothing to clear")
    // Clearing also drops a pending crop; with nothing applied that is not an undo step.
    session.setPendingCrop(a)
    #expect(!session.clearCrop())
    #expect(session.annotateMode?.pendingCrop == nil && crop(session) == nil)
    #expect(session.undoAnnotation() && crop(session) == b)
    #expect(session.undoAnnotation() && crop(session) == a)
    #expect(session.undoAnnotation() && crop(session) == nil)
    #expect(!session.undoAnnotation(), "set, replace, clear: three steps")
    // Undo or redo drops a pending crop first.
    session.setPendingCrop(c)
    #expect(session.redoAnnotation())
    #expect(session.annotateMode?.pendingCrop == nil && crop(session) == a)
    // Outside the crop tool there is no pending crop.
    session.selectAnnotateTool(.arrow)
    session.setPendingCrop(c)
    #expect(session.annotateMode?.pendingCrop == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693ToolChangeSaveAndLeaveApplyThePendingCrop() async {
    let (session, host) = await annotating()
    session.selectAnnotateTool(.crop)
    session.setPendingCrop(a)
    session.selectAnnotateTool(.crop)
    #expect(session.annotateMode?.pendingCrop == a, "choosing crop again keeps it pending")
    session.selectAnnotateTool(.arrow)
    #expect(crop(session) == a && session.annotateMode?.pendingCrop == nil, "another tool applies it")
    session.selectAnnotateTool(.crop)
    session.setPendingCrop(b)
    #expect(session.saveAnnotatedCopy())
    #expect(host.saves.last?.crop == b, "⌘S applies it first")
    #expect(crop(session) == b)
    session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/photos/photo-annotated.jpg")))
    session.setPendingCrop(c)
    #expect(session.requestLeaveAnnotateMode(.escape) == .ask, "leaving applies it and it is unsaved")
    #expect(crop(session) == c)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693SaveRequestCarriesTheCrop() async throws {
    let (session, host) = await annotating()
    session.addAnnotationMark(.redaction(rect: box, style: .solid))
    #expect(session.saveAnnotatedCopy())
    #expect(host.saves.last?.crop == nil)
    session.annotateSaveFinished(.saved(URL(fileURLWithPath: "/photos/photo-annotated.jpg")))
    session.selectAnnotateTool(.crop)
    session.setPendingCrop(CGRect(x: 1, y: 2, width: 3, height: 4))
    session.applyPendingCrop()
    #expect(session.saveAnnotatedCopy())
    #expect(host.saves.last?.crop == CGRect(x: 1, y: 2, width: 3, height: 4))
    #expect(host.saves.last?.marks.count == 1)
    // ⌘C's flatten is the crop's size.
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let copy = try session.flattenAnnotations(onto: image, orientation: 1)
    #expect(copy.width == 3 && copy.height == 4)
    // ⌘C applies a pending crop first, as one step.
    session.setPendingCrop(CGRect(x: 2, y: 2, width: 5, height: 6))
    let pending = try session.flattenAnnotations(onto: image, orientation: 1)
    #expect(pending.width == 5 && pending.height == 6)
    #expect(crop(session) == CGRect(x: 2, y: 2, width: 5, height: 6))
    #expect(session.undoAnnotation() && crop(session) == CGRect(x: 1, y: 2, width: 3, height: 4))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693EscapeCommandCancelsAPendingCrop() async {
    let (session, _) = await annotating()
    session.selectAnnotateTool(.crop)
    session.setPendingCrop(a)
    CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.escape, from: .menu, to: session)
    #expect(session.isAnnotating)
    #expect(session.annotateMode?.pendingCrop == nil && crop(session) == nil)
    #expect(session.annotateMode?.prompt == nil && session.annotateMode?.document.canUndo == false)
    // With nothing pending, Esc leaves as before.
    CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.escape, from: .menu, to: session)
    #expect(!session.isAnnotating)
}

@Test(.timeLimit(.minutes(2))) func issue693StateEqualityCountsStyleAndPendingCrop() {
    let base = AnnotateModeState(itemID: nil, fileURL: nil)
    var pending = base
    pending.pendingCrop = a
    var styled = base
    styled.redactionStyle = .solid
    #expect(base == AnnotateModeState(itemID: nil, fileURL: nil))
    #expect(base != pending)
    #expect(base != styled)
}

// MARK: - Keys (M12)

@Test(.timeLimit(.minutes(2))) func issue693KeyPolicyMapsMAndC() {
    func act(_ key: AnnotateKey, _ modifiers: AnnotateKeyModifiers = [], active: Bool = true, typing: Bool = false)
        -> AnnotateKeyAction? {
        AnnotateKeyPolicy.action(key: key, modifiers: modifiers, active: active, typing: typing)
    }
    #expect(act(.character("m")) == .chooseTool(.redact))
    #expect(act(.character("M"), [.shift]) == .chooseTool(.redact))
    #expect(act(.character("c")) == .chooseTool(.crop))
    #expect(act(.character("C"), [.shift]) == .chooseTool(.crop))
    #expect(act(.character("c"), [.command]) == nil, "⌘C stays Copy")
    #expect(act(.character("m"), [.option]) == nil)
    #expect(act(.character("c"), [.control]) == nil)
    #expect(act(.character("m"), active: false) == nil)
    #expect(act(.character("c"), typing: true) == nil)
    #expect(act(.returnKey) == .applyCrop)
    #expect(act(.returnKey, [.command]) == nil)
    #expect(act(.returnKey, active: false) == nil)
    #expect(act(.returnKey, typing: true) == nil)
}
