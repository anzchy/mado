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
    private var priorConsumeKey: ((NSEvent) -> Bool)?
    var panelEditor: RecogniseTextEditor? { overlay?.panelView?.textView }
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
        }, pasteboard: NativeTextPasteboard(pasteboard), isCurrent: { [weak self] identity in
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
        let overlay = RecogniseTextOverlay(frame: content.bounds)
        overlay.onDismiss = { [weak self] in self?.model?.dismissNotice() }
        overlay.onNoticeChange = { [weak self] in self?.controller?.relinkRecogniseTextNotice() }
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
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
        case .failed:
            overlay.showNotice(message: String(localized: "Unable to recognise text"),
                engine: nil, kind: .warning, onOpen: nil)
        }
        overlay.layoutSubtreeIfNeeded()
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
        window.contentMinSize = NSSize(width: window.contentMinSize.width, height: max(340, window.contentMinSize.height))
        if current.height < 340 {
            expandedFrom = current
            window.setContentSize(NSSize(width: current.width, height: 340))
        }
    }
    private func restoreWindowMinimumIfNeeded() {
        guard let window = controller?.window, let priorMinimum else { return }
        window.contentMinSize = priorMinimum
        self.priorMinimum = nil
        if let expandedFrom, abs((window.contentView?.bounds.height ?? 0) - 340) < 1 {
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
            if event.characters == "\u{1b}",
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               self?.overlay?.panelView != nil {
                self?.closePanel()
                return true
            }
            return previous?(event) ?? false
        }
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
                    self.model?.close()
                    self.overlay?.clear()
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
