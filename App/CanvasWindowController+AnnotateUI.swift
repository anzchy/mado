import AppKit
import UniformTypeIdentifiers
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// Page 39's views while Annotate Mode is on (#690 WI-6). The strip and the overlay live for the whole mode; the
/// confirmation and the sheet come and go.
/// i694-fix1: re-judges an annotate-on-show intent refused by ⌘E admission when a sheet ends, the first responder
/// changes or the window updates, until the intent enters or ends.
@MainActor final class AnnotateAdmissionWatch {
    let id: UUID
    var observers: [NSObjectProtocol] = []
    var responder: NSKeyValueObservation?
    init(id: UUID) { self.id = id }
    func end() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        responder?.invalidate()
        responder = nil
    }
}

struct AnnotateWindowViews {
    /// i694-fix1: the admission watch of a refused annotate-on-show intent.
    var admissionWatch: AnnotateAdmissionWatch?
    var strip: AnnotateStripView?
    var overlay: AnnotationOverlayView?
    /// #693: 遮挡's options beside the strip, shown while the redaction tool is chosen.
    var redactionOptions: AnnotateRedactionOptionsView?
    /// #693: the original is decoded once for the redaction patches, the first time a redaction is drawn.
    var redactionSourceRequested = false
    var confirmation: AnnotateSaveConfirmationView?
    /// The marks the confirmation reported; any change to them dismisses it.
    var confirmedMarks: [AnnotationMark]?
    var sheet: AnnotateLeaveSheetView?
    /// The chrome's own hidden state before the mode stepped it aside.
    var chromeWasHidden: Bool?
    /// Names this window saved in the folder; the scan may not have seen them yet.
    var savedNames: [String] = []
    /// The copy name the unsaved-marks sheet shows; 存储 writes it while it is still free (gpt M1, opus M2).
    var shownName: AnnotatedCopyName?
}

/// Page 39's in-window surfaces: the unsaved-marks sheet and the 「已存储为」 confirmation. The save panel and the
/// failure alert stay native (`AlertAnnotateUI`).
@MainActor final class InWindowAnnotateUI: AnnotateNativeUI {
    private weak var controller: CanvasWindowController?
    private let native = AlertAnnotateUI()

    init(controller: CanvasWindowController) { self.controller = controller }

    func askToLeave(_ reason: AnnotateLeaveReason, window: NSWindow?,
                    answer: @escaping @MainActor (AnnotateLeaveChoice) -> Void) {
        guard let controller, controller.presentAnnotateLeaveSheet(answer: answer) else {
            native.askToLeave(reason, window: window, answer: answer)
            return
        }
    }

    func chooseSaveLocation(folder: URL, name: String, type: UTType, window: NSWindow?) async -> URL? {
        await native.chooseSaveLocation(folder: folder, name: name, type: type, window: window)
    }

    /// The confirmation, plus the VoiceOver announcement the native surface posts.
    func showSaved(_ url: URL, window: NSWindow?) {
        native.showSaved(url, window: window)
        controller?.showAnnotateConfirmation(url)
    }

    func showSaveFailure(_ error: AnnotatedCopyError, window: NSWindow?) {
        native.showSaveFailure(error, window: window)
    }

    func regrantFolder(_ folder: URL, window: NSWindow?) async -> URL? {
        await native.regrantFolder(folder, window: window)
    }
}

extension CanvasWindowController {
    /// Page 39: the fit gives up 64 pt on the right (strip 48 + 12 to the edge + 4).
    static let annotateStripReserve: CGFloat = 64

    var annotateSheetShown: Bool { annotateViews.sheet != nil }

    /// Keeps page 39's views in step with the Session: installs them on entering, refreshes the strip and the
    /// marks, dismisses a confirmation whose marks changed, and tears everything down on leaving.
    func syncAnnotateUI() {
        guard let state = session.annotateMode else {
            tearDownAnnotateUI()
            return
        }
        guard let content = window?.contentView else { return }
        if annotateViews.strip == nil { installAnnotateUI(in: content) }
        annotateViews.overlay?.marks = state.document.marks
        annotateViews.overlay?.selectedMark = state.selectedMark
        annotateViews.overlay?.tool = state.tool
        annotateViews.overlay?.redactionStyle = state.redactionStyle
        annotateViews.overlay?.crop = state.document.crop
        annotateViews.overlay?.pendingCrop = state.pendingCrop
        if let options = annotateViews.redactionOptions {
            options.isHidden = state.tool != .redact
            let selected = state.selectedMark.flatMap { state.document.marks.indices.contains($0) ? state.document.marks[$0] : nil }
            let shown = selected?.redaction ?? state.redactionStyle
            if options.style != shown { options.update(shown) }
        }
        if state.document.marks.contains(where: { $0.kind == .redaction }) { loadAnnotateRedactionSource() }
        annotateViews.strip?.update(AnnotateStripState(tool: state.tool, canUndo: state.document.canUndo,
            canRedo: state.document.canRedo, canSave: session.canSaveAnnotatedCopy || annotatePendingText, canCopy: state.fileURL != nil))
        if let confirmed = annotateViews.confirmedMarks, confirmed != state.document.marks { dismissAnnotateConfirmation() }
    }

    private func installAnnotateUI(in content: NSView) {
        let overlay = AnnotationOverlayView(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.isActive = true
        overlay.onAddMark = { [weak self] mark in
            self?.session.addAnnotationMark(mark)
            self?.syncAnnotateUI()
        }
        overlay.onSelect = { [weak self] index in
            self?.session.selectAnnotationMark(index)
            self?.syncAnnotateUI()
        }
        overlay.onReplace = { [weak self] index, mark in
            self?.session.replaceAnnotationMark(at: index, with: mark)
            self?.syncAnnotateUI()
        }
        // #692 fix r1: VoiceOver's 删除 on a mark, as select + ⌫ (undoable). Ignored while typing or dragging, when the
        // indices are about to change.
        overlay.onDelete = { [weak self, weak overlay] index in
            guard let self, let overlay, !overlay.isEditingText, !overlay.isDragging else { return }
            self.session.selectAnnotationMark(index)
            self.session.deleteSelectedAnnotation()
            self.syncAnnotateUI()
        }
        // #692 fix r1: 存储 follows ⌘S while the text is typed.
        overlay.onTextChange = { [weak self] in self?.syncAnnotateUI() }
        overlay.onCommitText = { [weak self] index, text, origin, style in
            guard let self else { return }
            self.session.commitAnnotationText(text, at: origin, editing: index, style: style)
            // The keys go back to the canvas, so the next Esc and letters act on Annotate Mode again.
            self.applyFocus(.canvas)
            self.syncAnnotateUI()
        }
        // #693: the crop tool proposes a crop; Return, 完成 or another tool applies it.
        overlay.onCropChange = { [weak self] rect in
            self?.session.setPendingCrop(rect)
            self?.syncAnnotateUI()
        }
        content.addSubview(overlay)
        let strip = AnnotateStripView(frame: .zero)
        strip.onAction = { [weak self] action in self?.performAnnotateStripAction(action) }
        content.addSubview(strip)
        let options = AnnotateRedactionOptionsView()
        options.strip = strip
        options.isHidden = true
        options.onChange = { [weak self] style in
            guard let self else { return }
            self.session.setRedactionStyle(style)
            // opus M1: the keys go back to the canvas after a style choice, so M, C, ⌫ and ⌘Z act on Annotate Mode.
            self.applyFocus(.canvas)
            self.syncAnnotateUI()
        }
        content.addSubview(options)
        annotateViews.overlay = overlay
        annotateViews.strip = strip
        annotateViews.redactionOptions = options
        annotateViews.chromeWasHidden = chromeOverlay.isHidden
        chromeOverlay.isHidden = true
        canvas.trailingReserve = Self.annotateStripReserve
        annotateBackdropChanged(canvas.backdropFrame)
    }

    private func tearDownAnnotateUI() {
        guard annotateViews.strip != nil || annotateViews.overlay != nil || annotateViews.sheet != nil
            || annotateViews.confirmation != nil else { return }
        for view: NSView? in [annotateViews.overlay, annotateViews.strip, annotateViews.redactionOptions,
                              annotateViews.confirmation, annotateViews.sheet] {
            view?.removeFromSuperview()
        }
        let chromeWasHidden = annotateViews.chromeWasHidden
        annotateViews = AnnotateWindowViews(savedNames: annotateViews.savedNames)
        if let chromeWasHidden { chromeOverlay.isHidden = chromeWasHidden }
        canvas.trailingReserve = 0
    }

    /// The overlay draws in the canvas's coordinates.
    func annotateBackdropChanged(_ frame: CanvasBackdropFrame) {
        guard let overlay = annotateViews.overlay else { return }
        overlay.transform = frame.transform
        overlay.imageSize = frame.sourceSize
    }

    private func performAnnotateStripAction(_ action: AnnotateStripAction) {
        commitAnnotateText()
        switch action {
        case .tool(let tool): session.selectAnnotateTool(tool)
        case .undo: session.undoAnnotation()
        case .redo: session.redoAnnotation()
        case .copy: copy(nil)
        case .save: saveAnnotatedCopy()
        // #693: 完成 first applies a pending crop; with none it leaves.
        case .done: if !session.applyPendingCrop() { leaveAnnotateMode(.escape, proceed: {}) }
        }
        syncAnnotateUI()
    }

    /// ←/→/↑/↓ move the selected mark inside the image.
    func nudgeAnnotation(dx: Int, dy: Int) {
        session.nudgeSelectedAnnotation(dx: dx, dy: dy, imageSize: canvas.backdropFrame.sourceSize)
    }

    // MARK: Confirmation (page 39 `?saved=1`)

    /// 「已存储为 <name>」 with 在访达中显示; a second save replaces it.
    func showAnnotateConfirmation(_ url: URL) {
        guard let content = window?.contentView, let state = session.annotateMode else { return }
        dismissAnnotateConfirmation()
        let view = AnnotateSaveConfirmationView(fileName: url.lastPathComponent)
        view.onReveal = { [weak self] in self?.annotateRevealInFinder(url) }
        view.onClose = { [weak self] in self?.dismissAnnotateConfirmation() }
        if let sheet = annotateViews.sheet {
            content.addSubview(view, positioned: .below, relativeTo: sheet)
        } else {
            content.addSubview(view)
        }
        annotateViews.confirmation = view
        annotateViews.confirmedMarks = state.document.marks
    }

    private func dismissAnnotateConfirmation() {
        annotateViews.confirmation?.removeFromSuperview()
        annotateViews.confirmation = nil
        annotateViews.confirmedMarks = nil
    }

    /// Remembers a saved name in the original's folder for the sheet's planned name.
    func annotateRecordSaved(_ url: URL) {
        guard let source = session.annotateMode?.fileURL,
              url.deletingLastPathComponent().standardizedFileURL.path
                == source.deletingLastPathComponent().standardizedFileURL.path else { return }
        annotateViews.savedNames.append(url.lastPathComponent)
    }

    // MARK: Sheet (page 39 `?sheet=unsaved`)

    /// Shows the in-window sheet over everything; false when there is no window content or original to name.
    func presentAnnotateLeaveSheet(answer: @escaping @MainActor (AnnotateLeaveChoice) -> Void) -> Bool {
        guard let content = window?.contentView, let source = session.annotateMode?.fileURL else { return false }
        annotateViews.sheet?.removeFromSuperview()
        let scanned = annotateScannedName(for: source)
        let sheet = AnnotateLeaveSheetView(originalName: source.lastPathComponent, plannedName: scanned.name)
        sheet.onChoice = { [weak self, weak sheet] choice in
            guard let self, let sheet, self.annotateViews.sheet === sheet else { return }
            sheet.removeFromSuperview()
            self.annotateViews.sheet = nil
            if choice != .save { self.annotateViews.shownName = nil }
            answer(choice)
            self.syncAnnotateUI()
        }
        content.addSubview(sheet)
        annotateViews.sheet = sheet
        annotateViews.shownName = scanned
        syncAnnotateUI()
        refreshAnnotateSheetName(sheet, source: source)
        return true
    }

    /// Replaces the scan's name with one planned from a fresh listing, the way the save plans it.
    private func refreshAnnotateSheetName(_ sheet: AnnotateLeaveSheetView, source: URL) {
        Task { [weak self, weak sheet] in
            guard let self, let services = try? await self.accessServices.value else { return }
            let root = await services.files.rootCovering(source)
            let fresh = await self.annotatePlannedCopyName(for: source, services: services, root: root)
            guard let sheet, self.annotateViews.sheet === sheet else { return }
            sheet.plannedName = fresh.name
            self.annotateViews.shownName = fresh
        }
    }

    /// Keys while the sheet is up: Esc is 取消, Return is 存储, and nothing else reaches the mode.
    func consumeAnnotateSheetKey(_ event: NSEvent) -> Bool {
        guard let sheet = annotateViews.sheet else { return false }
        switch event.keyCode {
        case 53: sheet.cancelButton.performClick(nil)
        case 36, 76: sheet.saveButton.performClick(nil)
        default: break
        }
        return true
    }

    /// The name shown at once, from the folder scan and this window's saves, until the fresh listing arrives.
    private func annotateScannedName(for source: URL) -> AnnotatedCopyName {
        let folder = source.deletingLastPathComponent().standardizedFileURL.path
        let scanned = session.folderScan?.sourceSnapshot?.entries
            .filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == folder }
            .map(\.url.lastPathComponent) ?? []
        return AnnotatedCopyPlan.name(for: source.lastPathComponent, existing: scanned + annotateViews.savedNames,
                                      writableTypes: ImageIOWritableTypes.all)
    }

    /// The Session also leaves Annotate Mode on its own (a failed image, a folder change); the views follow.
    func observeAnnotateMode() {
        withObservationTracking {
            _ = session.annotateMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncAnnotateUI()
                self?.observeAnnotateMode()
            }
        }
    }
}
