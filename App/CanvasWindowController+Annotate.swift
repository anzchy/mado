import AppKit
import ImageIO
import UniformTypeIdentifiers
import MadoCore
import MadoApplication
import MadoInfrastructure

/// The native surfaces Annotate Mode asks through; tests replace them.
@MainActor protocol AnnotateNativeUI: AnyObject {
    /// 存储/不存储/取消 for unsaved marks.
    func askToLeave(_ reason: AnnotateLeaveReason, window: NSWindow?,
                    answer: @escaping @MainActor (AnnotateLeaveChoice) -> Void)
    /// A save panel prefilled with the original's folder and the planned name; nil when cancelled.
    func chooseSaveLocation(folder: URL, name: String, type: UTType, window: NSWindow?) async -> URL?
    func showSaved(_ url: URL, window: NSWindow?)
    func showSaveFailure(_ error: AnnotatedCopyError, window: NSWindow?)
}

/// What to do once a leave that asked 存储/不存储/取消 has been answered (and any save has finished).
struct AnnotatePendingLeave {
    let proceed: @MainActor () -> Void
    let refused: @MainActor () -> Void
}

/// Lets close and quit tell an answer given at once from one that arrives after a prompt or a save.
@MainActor final class AnnotateSyncAnswer {
    var waiting = true
    var value: Bool?
}

/// The native surfaces: a standard NSSavePanel and failure alert. Page 39's sheet and confirmation
/// (`InWindowAnnotateUI`) fall back to the alert and the announcement when the window has no content.
@MainActor final class AlertAnnotateUI: AnnotateNativeUI {
    func askToLeave(_ reason: AnnotateLeaveReason, window: NSWindow?,
                    answer: @escaping @MainActor (AnnotateLeaveChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the annotated copy before leaving?")
        alert.informativeText = String(localized: "Your marks will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(Self.choice(response)) }
            }
        } else {
            answer(Self.choice(alert.runModal()))
        }
    }

    nonisolated static func choice(_ response: NSApplication.ModalResponse) -> AnnotateLeaveChoice {
        switch response {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .discard
        default: .cancel
        }
    }

    func chooseSaveLocation(folder: URL, name: String, type: UTType, window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    /// The VoiceOver announcement; `InWindowAnnotateUI` adds page 39's confirmation.
    func showSaved(_ url: URL, window: NSWindow?) {
        let message = String(format: String(localized: "Saved as %@"), url.lastPathComponent)
        NSAccessibility.post(element: window ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func showSaveFailure(_ error: AnnotatedCopyError, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The annotated copy wasn't saved.")
        alert.informativeText = Self.reason(error)
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func reason(_ error: AnnotatedCopyError) -> String {
        switch error {
        case .permissionDenied: String(localized: "Mado isn't allowed to write in this folder.")
        case .diskFull: String(localized: "There isn't enough space on the disk.")
        case .folderMissing: String(localized: "The folder is no longer available.")
        case .sourceMissing: String(localized: "The original image is no longer available.")
        case .sourceIsTarget: String(localized: "The annotated copy can't replace the original image.")
        case .accessLost: String(localized: "Mado no longer has access to this folder.")
        case .encodeFailed, .nameExhausted, .writeFailed: String(localized: "The file couldn't be written.")
        }
    }
}

/// #690 (P7-11): Annotate Mode in the viewer window. The Session owns the state; this wires keys, menus, the
/// unsaved-marks prompt, close and quit, and performs the save (decode, flatten, plan, write or save panel).
extension CanvasWindowController {
    var canEnterAnnotateFromMenu: Bool {
        !session.isAnnotating && !(window?.firstResponder is NSTextInputClient) && window?.attachedSheet == nil
            && session.canEnterAnnotateMode
    }
    var canSaveAnnotatedCopyFromMenu: Bool {
        session.canSaveAnnotatedCopy && window?.attachedSheet == nil && !annotateSheetShown
    }

    /// ⌘E.
    func enterAnnotateMode() {
        guard canEnterAnnotateFromMenu else { return }
        session.enterAnnotateMode()
        syncAnnotateUI()
    }

    /// ⌘S: stays in Annotate Mode.
    func saveAnnotatedCopy() {
        guard canSaveAnnotatedCopyFromMenu else { return }
        session.saveAnnotatedCopy()
        syncAnnotateUI()
    }

    /// Opening another image, a folder or a recent folder first leaves Annotate Mode; with unsaved marks the
    /// answer decides, and `retry` runs the original request once the mode has ended.
    func annotateAllowsImageChange(retry: @escaping @MainActor () -> Void) -> Bool {
        guard session.isAnnotating else { return true }
        leaveAnnotateMode(.changeImage, proceed: retry)
        return false
    }

    /// Keys inside Annotate Mode: V, R, Esc, ⌘Z/⇧⌘Z, and ←/→/↑/↓ nudging the selected mark (never changing
    /// images). While page 39's sheet is up it takes every key. nil leaves the key to browsing.
    func consumeAnnotateKey(_ event: NSEvent) -> Bool? {
        guard session.isAnnotating, window?.attachedSheet == nil, !menuTracking() else { return nil }
        if consumeAnnotateSheetKey(event) { return true }
        let key: AnnotateKey = switch event.keyCode {
        case 53: .escape
        case 123: .leftArrow
        case 124: .rightArrow
        case 125: .downArrow
        case 126: .upArrow
        default: .character(event.charactersIgnoringModifiers ?? "")
        }
        var modifiers: AnnotateKeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let focus = focusContext
        guard let action = AnnotateKeyPolicy.action(key: key, modifiers: modifiers, active: true,
                                                    typing: focus == .textInput) else { return nil }
        switch action {
        case .selectRectangle: session.selectAnnotateTool(.rectangle)
        case .undo: session.undoAnnotation()
        case .redo: session.redoAnnotation()
        case .selectTool: session.selectAnnotateTool(.select)
        // ←/→/↑/↓ stay consumed even without a selection, so they never change images.
        case .nudge(let dx, let dy): nudgeAnnotation(dx: dx, dy: dy)
        case .requestLeave:
            // Esc first returns focus from a panel or tool to the canvas, as outside Annotate Mode.
            guard focus == .canvas else { return nil }
            leaveAnnotateMode(.escape, proceed: {})
        }
        syncAnnotateUI()
        return true
    }

    /// The menu's bare Esc reaches `route` before the window sees the key.
    func routeAnnotateEscape() -> Bool {
        guard session.isAnnotating else { return false }
        if let sheet = annotateViews.sheet {
            sheet.cancelButton.performClick(nil)
            return true
        }
        guard session.inspectorFocus.focus == .canvas else { return false }
        leaveAnnotateMode(.escape, proceed: {})
        return true
    }

    /// ⌘Q and the Dock's Quit: asks while marks are unsaved and replies once answered (and saved).
    func annotateShouldTerminate() -> NSApplication.TerminateReply {
        guard session.isAnnotating else { return .terminateNow }
        let answer = AnnotateSyncAnswer()
        leaveAnnotateMode(.quitApp, proceed: { [weak self] in
            if answer.waiting { answer.value = true } else { self?.annotateTerminateReply(true) }
        }, refused: { [weak self] in
            if answer.waiting { answer.value = false } else { self?.annotateTerminateReply(false) }
        })
        answer.waiting = false
        switch answer.value {
        case true?: return .terminateNow
        case false?: return .terminateCancel
        case nil: return .terminateLater
        }
    }

    /// The close button and ⌘W: asks while marks are unsaved; 存储 closes the window once the copy is written.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.isAnnotating else { return true }
        let answer = AnnotateSyncAnswer()
        leaveAnnotateMode(.closeWindow, proceed: { [weak self] in
            if answer.waiting { answer.value = true } else { self?.window?.close() }
        })
        answer.waiting = false
        return answer.value == true
    }

    /// One leave at a time: a second request while a prompt or a save is pending is refused.
    func leaveAnnotateMode(_ reason: AnnotateLeaveReason, proceed: @escaping @MainActor () -> Void,
                           refused: @escaping @MainActor () -> Void = {}) {
        guard annotatePendingLeave == nil, session.annotateMode?.isSaving != true else { refused(); return }
        defer { syncAnnotateUI() }
        switch session.requestLeaveAnnotateMode(reason) {
        case .proceed: proceed()
        case .ask:
            annotatePendingLeave = AnnotatePendingLeave(proceed: proceed, refused: refused)
            annotateUI.askToLeave(reason, window: window) { [weak self] choice in
                guard let self else { return }
                self.finishAnnotateLeave(self.session.resolveAnnotatePrompt(choice))
            }
        case .saving, .refused: refused()
        }
    }

    private func finishAnnotateLeave(_ outcome: AnnotateLeaveOutcome) {
        defer { syncAnnotateUI() }
        guard outcome != .saving, outcome != .ask, let pending = annotatePendingLeave else { return }
        annotatePendingLeave = nil
        if outcome == .proceed { pending.proceed() } else { pending.refused() }
    }

    /// The image, decoded at full size from the original, with its EXIF orientation.
    private struct AnnotateSource: @unchecked Sendable { let image: CGImage, orientation: Int }

    private func annotateAccess(_ source: URL) async throws(AnnotatedCopyError)
        -> (AccessServices, AccessRequest, AccessRootID?) {
        guard let services = try? await accessServices.value else { throw .accessLost }
        let root = await services.files.rootCovering(source)
        return (services, root.map { .root($0, file: source) } ?? .fileGrant(source), root)
    }

    private nonisolated static func decodeOriginal(_ url: URL) throws(AnnotatedCopyError) -> AnnotateSource {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .sourceMissing }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw .encodeFailed }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return AnnotateSource(image: image, orientation: properties?[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// Reads the original under its lease; a missing file or a lost grant is a typed reason.
    private func annotateFlattened(_ source: URL, marks: [AnnotationMark], services: AccessServices,
                                   access: AccessRequest) async throws(AnnotatedCopyError) -> AnnotateSource {
        let original: AnnotateSource
        do {
            // A root lease names the root folder; a File Grant lease names the (possibly moved) file itself.
            original = try await services.files.withLease(access) { lease in
                try Self.decodeOriginal(lease.rootID == nil ? lease.url : source)
            }
        } catch let error as AnnotatedCopyError { throw error }
        catch FileAccessError.fileDeleted(_) { throw .sourceMissing }
        catch { throw FileManager.default.fileExists(atPath: source.path) ? .accessLost : .sourceMissing }
        do {
            let flat = try AnnotationFlattener.flatten(original.image, orientation: original.orientation, marks: marks)
            return AnnotateSource(image: flat, orientation: 1)
        } catch { throw .encodeFailed }
    }

    private func runAnnotatedCopySave(_ request: AnnotateSaveRequest) async -> AnnotateSaveResult {
        guard let source = request.fileURL else { return .failed(.sourceMissing) }
        do throws(AnnotatedCopyError) {
            let (services, access, root) = try await annotateAccess(source)
            let flat = try await annotateFlattened(source, marks: request.marks, services: services, access: access)
            let folder = source.deletingLastPathComponent()
            let existing: [String]
            if let root {
                existing = (try? await services.files.withLease(.root(root, file: folder)) { _ in
                    try FileManager.default.contentsOfDirectory(atPath: folder.path)
                }) ?? []
            } else { existing = [] }
            let planned = AnnotatedCopyPlan.name(for: source.lastPathComponent, existing: existing,
                                                 writableTypes: ImageIOWritableTypes.all)
            let writer = AnnotatedCopyWriter(leases: services.files)
            switch request.destination(folder: folder, name: planned.name, access: root == nil ? .fileGrant : .accessRoot) {
            case .direct:
                do throws(AnnotatedCopyError) {
                    return .saved(try await writer.write(flat.image, folder: folder, target: .create(planned),
                                                         source: source, request: access))
                } catch {
                    guard error == .permissionDenied else { throw error }
                    // A refused direct write opens the prefilled panel for the same ⌘S (ADR-020).
                    return try await annotatePanelSave(flat, planned: planned, folder: folder, source: source,
                                                       access: access, writer: writer, afterRefusal: true)
                }
            case .savePanel:
                return try await annotatePanelSave(flat, planned: planned, folder: folder, source: source,
                                                   access: access, writer: writer, afterRefusal: request.directRefused)
            }
        } catch {
            return .failed(error)
        }
    }

    private func annotatePanelSave(_ flat: AnnotateSource, planned: AnnotatedCopyName, folder: URL, source: URL,
                                   access: AccessRequest, writer: AnnotatedCopyWriter,
                                   afterRefusal: Bool) async throws(AnnotatedCopyError) -> AnnotateSaveResult {
        guard let chosen = await annotateUI.chooseSaveLocation(folder: folder, name: planned.name, type: planned.type,
                                                               window: window) else {
            // Cancelling the panel that replaced a refused direct write still reports the refusal.
            return afterRefusal ? .failed(.permissionDenied) : .panelCancelled
        }
        return .saved(try await writer.write(flat.image, folder: chosen.deletingLastPathComponent(),
                                             target: .replace(chosen, type: planned.type), source: source, request: access))
    }

    private func annotateSaveEnded(_ result: AnnotateSaveResult) {
        if case .saved(let url) = result { annotateRecordSaved(url) }
        let outcome = session.annotateSaveFinished(result)
        defer { syncAnnotateUI() }
        switch result {
        case .saved(let url): annotateUI.showSaved(url, window: window)
        case .failed(let error): annotateUI.showSaveFailure(error, window: window)
        case .panelCancelled: break
        }
        if let outcome { finishAnnotateLeave(outcome) }
    }

    /// ⌘C: the flattened full image; nothing is written and the marks stay unsaved.
    private func copyAnnotatedImage() {
        guard let state = session.annotateMode, let source = state.fileURL else { return }
        let marks = state.document.marks
        let pasteboard = annotatePasteboard
        Task { [weak self] in
            guard let self else { return }
            do throws(AnnotatedCopyError) {
                let (services, access, _) = try await self.annotateAccess(source)
                let flat = try await self.annotateFlattened(source, marks: marks, services: services, access: access)
                let image = NSImage(cgImage: flat.image, size: NSSize(width: flat.image.width, height: flat.image.height))
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            } catch {
                self.annotateUI.showSaveFailure(error, window: self.window)
            }
        }
    }
}

extension CanvasWindowController: AnnotateSaveHost {
    func performAnnotatedCopySave(_ request: AnnotateSaveRequest) {
        annotateSaveTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.runAnnotatedCopySave(request)
            self.annotateSaveTask = nil
            self.annotateSaveEnded(result)
        }
    }
}

extension CanvasWindowController: NSMenuItemValidation {
    /// Edit › Undo/Redo/Copy reach the window controller only when no text field claims them.
    /// Page 39's sheet blocks them like a native sheet would.
    @objc func undo(_ sender: Any?) {
        guard !annotateSheetShown else { return }
        session.undoAnnotation()
        syncAnnotateUI()
    }
    @objc func redo(_ sender: Any?) {
        guard !annotateSheetShown else { return }
        session.redoAnnotation()
        syncAnnotateUI()
    }
    @objc func copy(_ sender: Any?) {
        guard !annotateSheetShown else { return }
        copyAnnotatedImage()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let state = annotateSheetShown ? nil : session.annotateMode
        switch item.action {
        case #selector(undo(_:)): return state?.document.canUndo == true
        case #selector(redo(_:)): return state?.document.canRedo == true
        case #selector(copy(_:)): return state?.fileURL != nil
        // Other actions the window controller answers keep their default (enabled).
        default: return true
        }
    }
}
