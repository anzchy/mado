import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import MadoApplication
import MadoInfrastructure

/// One adapter per viewer window. The model owns admission; this object owns native window effects.
@MainActor final class ViewerRecogniseTextAdapter {
    weak var controller: CanvasWindowController?
    var pasteboard: NSPasteboard = .general
    var recognise: @Sendable (Data, TextRecognitionIntent) async throws -> TextRecognitionResult = { data, intent in
        try await TextRecognitionService(onDevice: OnDeviceTextRecognitionProvider()).recognise(data, intent: intent)
    }
    private(set) var model: RecogniseTextModel?
    private var overlay: RecogniseTextOverlay?
    nonisolated(unsafe) private var closeObserver: (any NSObjectProtocol)?
    private var activeGeneration: UUID?
    private var activeRun = UUID()
    private var closed = false
    private var priorMinimum: NSSize?
    private var expandedFrom: NSSize?
    private var panelHeight: CGFloat = 340
    private var priorConsumeKey: ((NSEvent) -> Bool)?
    /// #687 fix r5: the notice's 5 s dismissal clock; tests replace it before the first recognition.
    var scheduleNoticeDismiss: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)?
    /// #687 fix r5b (F9): posts a VoiceOver announcement; tests record it instead.
    lazy var announce: (String) -> Void = { [weak self] message in
        NSAccessibility.post(element: self?.controller?.window ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private var announcedRun: UUID?
    /// #687 fix r5b (F11): builds the clipboard writer; tests replace it.
    var makeTextPasteboard: (NSPasteboard) -> any TextPasteboardWriting = { NativeTextPasteboard($0) }
    /// #687 fix r5b (F12): where the pointer rests, in window coordinates; tests replace it.
    var pointerLocation: (() -> NSPoint?)?
    /// The panel's Esc wrapper is installed.
    var hasPanelKeyRouting: Bool { priorConsumeKey != nil }
    var panelEditor: RecogniseTextEditor? { overlay?.panelView?.textView }
    /// #687 fix r5 (F5): the OCR editor holds an input method's marked text.
    var isComposing: Bool { panelEditor?.hasMarkedText() == true }
    /// #687 fix r5 (F6): the open panel's key views, in Tab order.
    var panelKeyViews: [NSView] {
        guard let panel = overlay?.panelView else { return [] }
        return [panel.textView, panel.copyButton, panel.closeButton]
    }
    /// The viewer's trailing key views: the panel's while it is open, otherwise a success notice.
    var trailingKeyViews: [NSView] {
        let panel = panelKeyViews
        return panel.isEmpty ? (focusableNotice.map { [$0] } ?? []) : panel
    }
    /// #687 fix r5 (F6): set while the panel's own Tab hands focus to the Inspector, which preserveResponder would
    /// otherwise refuse as the opening's focus replay.
    private(set) var allowsInspectorFocus = false
    var focusableNotice: RecogniseTextNoticeView? {
        guard let notice = overlay?.noticeView, notice.kind == .success else { return nil }
        return notice
    }

    init(controller: CanvasWindowController) {
        self.controller = controller
        if let window = controller.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: nil) { [weak self] _ in
                // NSWindow posts willClose on the main actor. Invalidate before
                // close returns so a late OCR completion cannot copy afterward.
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
        observeImageGeneration()
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    var canStart: Bool {
        guard let controller, !closed, controller.window != nil,
              !controller.session.isAnnotating, !controller.canvas.isHidden,
              controller.canvas.backdropFrame.image != nil else { return false }
        return model?.isRunning != true
    }

    func start() {
        guard canStart, let controller, let image = controller.canvas.backdropFrame.image else { return }
        let generation = controller.session.imageLoader.generation
        let presentedKey = controller.session.imageLoader.presented?.key
        let sourceSize = controller.canvas.backdropFrame.sourceSize
        let imageLoader = controller.session.imageLoader
        activeGeneration = generation
        activeRun = UUID()
        let run = activeRun
        let recognise = self.recognise
        let newModel = RecogniseTextModel(recognise: { _ in
            let needsFullResolution = image.width != Int(sourceSize.width) || image.height != Int(sourceSize.height)
            let sourceImage = needsFullResolution
                ? try await imageLoader.recognitionImage(maximumPixelSize: max(Int(sourceSize.width), Int(sourceSize.height)))
                : nil
            let data = try await Self.sourceData(image: sourceImage ?? image)
            try Task.checkCancellation()
            return try await recognise(data, .explicit)
        }, pasteboard: makeTextPasteboard(pasteboard), isCurrent: { [weak self] identity in
            guard let self, let controller = self.controller,
                  controller.canvas.backdropFrame.image != nil else { return false }
            let currentKey = controller.session.imageLoader.presented?.key
            return !self.closed && identity == self.activeRun && identity == run
                && controller.session.imageLoader.generation == generation
                && currentKey?.itemID == presentedKey?.itemID
                && currentKey?.revision == presentedKey?.revision
        }, onChange: { [weak self] in self?.render() })
        model?.close()
        model = newModel
        ensureOverlay()
        newModel.start(Data(), identity: run)
    }

    private nonisolated static func sourceData(image: CGImage) async throws -> Data {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
                throw TextRecognitionError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw TextRecognitionError.invalidImage }
            try Task.checkCancellation()
            return buffer as Data
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func ensureOverlay() {
        guard overlay == nil, let content = controller?.window?.contentView else { return }
        let overlay = scheduleNoticeDismiss.map { RecogniseTextOverlay(frame: content.bounds, scheduleDismiss: $0) }
            ?? RecogniseTextOverlay(frame: content.bounds)
        // #687 fix r5: removing a focused notice or panel (timer, a new run, an image change) leaves the window as
        // first responder. The Session moves to the canvas first, or preserveResponder refuses the canvas.
        overlay.handOffFocus = { [weak self] removal in
            guard let self, !self.closed, let controller = self.controller else { removal(); return }
            controller.session.updateFocus(.canvas)
            removal()
            _ = controller.window?.makeFirstResponder(controller.canvas)
        }
        // #687 fix r5b (F8): keep clear of the viewer's chrome pods. Their frames hold while the chrome auto-hides,
        // so the notice does not jump under a resting pointer when the pods come back.
        // #687 fix r5b (F10): with the Inspector shown, keep left of its column, unless that leaves less than the
        // panel's full 260 pt (a narrow window keeps the window edge).
        overlay.placement = { [weak self, weak overlay] in
            guard let overlay, let controller = self?.controller, let chrome = controller.chromeOverlay,
                  chrome.window === overlay.window else {
                return RecogniseTextPlacement(trailingEdge: nil, obstacles: [])
            }
            let column = controller.recogniseTextInspectorColumn.flatMap { frame in
                overlay.superview.map { overlay.convert(frame, from: $0) }
            }
            let trailing = column.map(\.minX).flatMap { $0 - overlay.bounds.minX - 40 >= 260 ? $0 : nil }
            return RecogniseTextPlacement(trailingEdge: trailing,
                obstacles: chrome.groups.map { overlay.convert($0.frame, from: chrome) })
        }
        overlay.pointerLocation = { [weak self] in self?.pointerLocation?() }
        overlay.onDismiss = { [weak self] in self?.model?.dismissNotice() }
        overlay.onNoticeChange = { [weak self] in self?.controller?.relinkRecogniseTextNotice() }
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
    }

    /// #687 fix r5b (F10): the Inspector was shown or hidden; the notice and the panel follow its edge.
    func relayout() {
        overlay?.needsLayout = true
        overlay?.layoutSubtreeIfNeeded()
    }

    private func render() {
        guard let model else { return }
        ensureOverlay()
        guard let overlay else { return }
        if let panelText = model.panelText, let engine = model.engine {
            if overlay.panelView == nil {
                fitWindowForPanel()
                installPanelKeyRouting()
                overlay.showPanel(text: panelText, engine: Self.label(for: engine),
                    onEdit: { [weak self] in self?.model?.edit($0) },
                    onCopy: { [weak self] in
                        self?.model?.copyEditedText()
                        if let editor = self?.overlay?.panelView?.textView {
                            _ = self?.controller?.window?.makeFirstResponder(editor)
                        }
                    },
                    onClose: { [weak self] in self?.closePanel() })
                overlay.layoutSubtreeIfNeeded()
                if let editor = overlay.panelView?.textView { _ = controller?.window?.makeFirstResponder(editor) }
            }
            overlay.panelView?.showCopiedConfirmation(model.copiedConfirmation)
            return
        }
        restorePanelKeyRouting()
        restoreWindowMinimumIfNeeded()
        guard let notice = model.notice else { overlay.clear(); return }
        switch notice {
        case .copied(let count, let engine):
            let message = String(format: String(localized: "Copied %lld characters"), Int64(count))
            overlay.showNotice(message: message, engine: Self.label(for: engine), kind: .success,
                onOpen: { [weak self] in self?.model?.openPanel() })
        case .noText:
            overlay.showNotice(message: String(localized: "No text found · Clipboard unchanged"),
                engine: nil, kind: .warning, onOpen: nil)
        case .clipboardMayHaveChanged:
            overlay.showNotice(message: String(localized: "Couldn't copy the text · The clipboard may have changed"),
                engine: nil, kind: .warning, onOpen: nil)
        case .failed:
            overlay.showNotice(message: String(localized: "Unable to recognise text"),
                engine: nil, kind: .warning, onOpen: nil)
        }
        overlay.layoutSubtreeIfNeeded()
        // #687 fix r5b (F9): VoiceOver hears each recognition's result once, as Annotate's showSaved does.
        if announcedRun != activeRun, let label = overlay.noticeView?.accessibilityLabel() {
            announcedRun = activeRun
            announce(label)
        }
    }

    private static func label(for engine: TextRecognitionEngine) -> String {
        switch engine {
        case .onDevice: String(localized: "On-device Recognition")
        case .cloud: String(localized: "Baidu Cloud Recognition")
        }
    }

    private func fitWindowForPanel() {
        guard let window = controller?.window, priorMinimum == nil else { return }
        priorMinimum = window.contentMinSize
        let current = window.contentView?.bounds.size ?? .zero
        // #687 fix r5b (F8): the panel sits above the zoom group, so the window keeps 20 pt over its top edge.
        let needed = max(340, ceil(overlay?.plannedPanelFrame().maxY ?? 0) + 20)
        panelHeight = needed
        window.contentMinSize = NSSize(width: window.contentMinSize.width, height: max(needed, window.contentMinSize.height))
        if current.height < needed {
            expandedFrom = current
            window.setContentSize(NSSize(width: current.width, height: needed))
        }
    }
    private func restoreWindowMinimumIfNeeded() {
        guard let window = controller?.window, let priorMinimum else { return }
        window.contentMinSize = priorMinimum
        self.priorMinimum = nil
        if let expandedFrom, abs((window.contentView?.bounds.height ?? 0) - panelHeight) < 1 {
            let currentWidth = window.contentView?.bounds.width ?? expandedFrom.width
            window.setContentSize(NSSize(width: currentWidth, height: expandedFrom.height))
        }
        expandedFrom = nil
    }
    func closePanel() {
        restorePanelKeyRouting()
        model?.closePanel()
        restoreWindowMinimumIfNeeded()
        if let controller {
            controller.session.updateFocus(.canvas)
            _ = controller.window?.makeFirstResponder(controller.canvas)
        }
    }
    /// A mode switch ends the explicit OCR run and releases its editor and key wrapper.
    func leaveForAnnotate() {
        activeRun = UUID()
        restorePanelKeyRouting()
        model?.close()
        overlay?.clear()
        restoreWindowMinimumIfNeeded()
        if let controller {
            controller.session.updateFocus(.canvas)
            _ = controller.window?.makeFirstResponder(controller.canvas)
        }
    }
    private func windowClosed() {
        restorePanelKeyRouting()
        closed = true
        activeRun = UUID()
        model?.close()
        overlay?.clear()
        overlay?.removeFromSuperview(); overlay = nil
    }

    private func installPanelKeyRouting() {
        guard priorConsumeKey == nil, let window = controller?.window as? CommandWindow else { return }
        let previous = window.consumeKey
        priorConsumeKey = previous ?? { _ in false }
        window.consumeKey = { [weak self] event in
            guard let self, self.overlay?.panelView != nil else { return previous?(event) ?? false }
            // #687 fix r5 (F5, review M4): while the focused text input composes (the OCR editor or any other field),
            // every key goes to the input method first.
            if (self.controller?.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if event.characters == "\u{1b}", plain {
                self.closePanel()
                return true
            }
            if event.keyCode == 48, plain, self.routePanelTab(reverse: event.modifierFlags.contains(.shift)) { return true }
            return previous?(event) ?? false
        }
    }

    /// #687 fix r5 (F6): editor → 拷贝 → 关闭 → Inspector (when shown) or canvas; Shift-Tab walks back. Shift-Tab
    /// from the editor leaves for the previous key view (the last viewer control). Tab in the editor moves focus
    /// rather than typing a tab: the recognised text is plain and single-purpose.
    private func routePanelTab(reverse: Bool) -> Bool {
        guard let controller, let window = controller.window, let panel = overlay?.panelView else { return false }
        let ring = panelKeyViews
        let responder = window.firstResponder as? NSView
        if let responder, let index = ring.firstIndex(where: { $0 === responder }) {
            if reverse {
                if index > 0 { _ = window.makeFirstResponder(ring[index - 1]) } else { window.selectKeyView(preceding: panel.textView) }
            } else if index < ring.count - 1 {
                _ = window.makeFirstResponder(ring[index + 1])
            } else if !focusInspector() {
                controller.session.updateFocus(.canvas)
                _ = window.makeFirstResponder(controller.canvas)
            }
            return true
        }
        guard controller.recogniseTextInspectorFocused else { return false }
        if reverse {
            _ = window.makeFirstResponder(panel.closeButton)
        } else {
            controller.session.updateFocus(.canvas)
            _ = window.makeFirstResponder(controller.canvas)
        }
        return true
    }
    private func focusInspector() -> Bool {
        allowsInspectorFocus = true
        defer { allowsInspectorFocus = false }
        return controller?.focusInspectorFromRecogniseText() == true
    }

    private func restorePanelKeyRouting() {
        guard let priorConsumeKey else { return }
        (controller?.window as? CommandWindow)?.consumeKey = priorConsumeKey
        self.priorConsumeKey = nil
    }

    private func observeImageGeneration() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.session.imageLoader.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let activeGeneration,
                   self.controller?.session.imageLoader.generation != activeGeneration {
                    self.activeRun = UUID()
                    self.restorePanelKeyRouting()
                    self.model?.close()
                    self.overlay?.clear()
                    self.restoreWindowMinimumIfNeeded()
                    self.activeGeneration = nil
                }
                self.observeImageGeneration()
            }
        }
    }
}

extension CanvasWindowController {
    var canRecogniseTextFromMenu: Bool { recogniseTextAdapter.canStart }
    func recogniseText() { recogniseTextAdapter.start() }
}
