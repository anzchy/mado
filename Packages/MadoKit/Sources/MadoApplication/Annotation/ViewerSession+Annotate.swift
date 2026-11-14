import CoreGraphics
import Foundation
import MadoCore

/// #690 (P7-11): Annotate Mode on the shown image. While it is active, browsing is off (see `isEnabled`), the
/// Preview Set stays on the annotated image, and leaving with unsaved marks asks 存储/不存储/取消.
extension ViewerSession {
    public var isAnnotating: Bool { annotateMode != nil }

    /// ⌘E: only while viewing a shown image, and never while typing.
    public var canEnterAnnotateMode: Bool {
        AnnotateModeState.canEnter(mode: mode, hasImage: host?.hasImage == true, status: imageStatus,
                                   focus: inspectorFocus.focus)
    }

    /// Enters on the current image; entering again keeps the document.
    public func enterAnnotateMode() {
        guard annotateMode == nil, canEnterAnnotateMode else { return }
        annotateMode = AnnotateModeState(itemID: currentItemID, fileURL: imageLoader.fileURL)
        annotateMode?.tool = .rectangle
        // #690 fix r1: page 39's strip and image reserve sit where the Inspector would; it closes on entering.
        if inspectorFocus.isVisible { setInspectorVisible(false) }
    }

    /// V and R: only inside Annotate Mode.
    public func selectAnnotateTool(_ tool: AnnotateTool) { annotateMode?.tool = tool }

    /// A new mark becomes the selection, so ←/→/↑/↓ move it at once.
    public func addAnnotationMark(_ mark: AnnotationMark) {
        guard var state = annotateMode else { return }
        state.document.add(mark)
        state.selectedMark = state.document.marks.count - 1
        annotateMode = state
    }

    /// The select tool's click; nil clears the selection, an index outside the marks is ignored.
    public func selectAnnotationMark(_ index: Int?) {
        guard let state = annotateMode else { return }
        if let index, !state.document.marks.indices.contains(index) { return }
        annotateMode?.selectedMark = index
    }

    /// ←/→/↑/↓: moves the selected mark inside the image as an undoable change; without a selection nothing changes.
    @discardableResult public func nudgeSelectedAnnotation(dx: Int, dy: Int, imageSize: CGSize) -> Bool {
        guard var state = annotateMode, let index = state.selectedMark,
              state.document.marks.indices.contains(index) else { return false }
        var mark = state.document.marks[index]
        let moved = AnnotationGeometry.nudge(mark.rect, dx: dx, dy: dy, imageSize: imageSize)
        guard moved != mark.rect else { return false }
        mark.rect = moved
        state.document.replace(at: index, with: mark)
        annotateMode = state
        return true
    }

    @discardableResult public func undoAnnotation() -> Bool { keepSelectionValid(annotateMode?.document.undo() ?? false) }

    @discardableResult public func redoAnnotation() -> Bool { keepSelectionValid(annotateMode?.document.redo() ?? false) }

    /// Undo and redo can remove the selected mark; the selection then clears.
    private func keepSelectionValid(_ changed: Bool) -> Bool {
        if let state = annotateMode, let index = state.selectedMark, index >= state.document.marks.count {
            annotateMode?.selectedMark = nil
        }
        return changed
    }

    /// Esc, closing the window, quitting or changing the image. Without unsaved marks the mode ends at once.
    public func requestLeaveAnnotateMode(_ reason: AnnotateLeaveReason) -> AnnotateLeaveOutcome {
        guard let state = annotateMode, state.needsPrompt else { exitAnnotateMode(); return .proceed }
        annotateMode?.prompt = reason
        return .ask
    }

    /// The answer to the prompt. Save starts a save and ends the mode only when it succeeds.
    @discardableResult public func resolveAnnotatePrompt(_ choice: AnnotateLeaveChoice) -> AnnotateLeaveOutcome {
        guard let reason = annotateMode?.prompt else { return .refused }
        annotateMode?.prompt = nil
        switch choice {
        case .cancel: return .refused
        case .discard: exitAnnotateMode(); return .proceed
        case .save: startSave(leave: reason); return .saving
        }
    }

    /// ⌘S: needs at least one mark and no save already in flight.
    public var canSaveAnnotatedCopy: Bool { annotateMode?.document.canSave == true && annotateMode?.isSaving == false }

    /// ⌘S hands one save to the host and stays in Annotate Mode.
    @discardableResult public func saveAnnotatedCopy() -> Bool {
        guard canSaveAnnotatedCopy else { return false }
        startSave(leave: nil)
        return true
    }

    /// The host reports how the save ended. Returns the outcome of the leave it completes, or nil for a plain ⌘S.
    @discardableResult public func annotateSaveFinished(_ result: AnnotateSaveResult) -> AnnotateLeaveOutcome? {
        guard let saving = annotateMode?.saving else { return nil }
        annotateMode?.saving = nil
        switch result {
        case .saved(let url):
            annotateMode?.document.markSaved(revision: saving.revision)
            annotateMode?.lastSavedURL = url
            annotateMode?.lastSaveError = nil
        case .failed(let error):
            annotateMode?.lastSaveError = error
            if AnnotatedCopyPlan.refusesDirectWrite(error) { annotateMode?.directRefused = true }
        case .panelCancelled:
            annotateMode?.lastSaveError = nil
        }
        guard saving.leave != nil else { return nil }
        guard case .saved = result, annotateMode?.needsPrompt == false else { return .refused }
        exitAnnotateMode()
        return .proceed
    }

    /// ⌘C: the flattened full image; nothing is written and the unsaved state does not change.
    public func flattenAnnotations(onto image: CGImage, orientation: Int) throws -> CGImage {
        try AnnotationFlattener.flatten(image, orientation: orientation, marks: annotateMode?.document.marks ?? [])
    }

    private func startSave(leave: AnnotateLeaveReason?) {
        guard let state = annotateMode else { return }
        annotateMode?.saving = (state.document.revision, leave)
        (host as? any AnnotateSaveHost)?.performAnnotatedCopySave(AnnotateSaveRequest(
            fileURL: state.fileURL, marks: state.document.marks, directRefused: state.directRefused))
    }

    /// Ends the mode; a deletion held back while annotating now moves the Preview Set on.
    private func exitAnnotateMode() {
        guard annotateMode != nil else { return }
        annotateMode = nil
        let state = browsingState
        updateItems(state.items, sourceVersion: state.sourceVersion)
    }
}
