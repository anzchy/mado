import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import MadoApplication
import MadoCore
import MadoInfrastructure
import MadoMacUI

/// The only retained recognition result belongs to the current viewer item.
@MainActor final class ViewerSelectTextAdapter {
    weak var controller: CanvasWindowController?
    var pasteboard: NSPasteboard = .general
    var recognise: @Sendable (Data, TextRecognitionIntent) async throws -> TextRecognitionResult = { data, intent in
        try await TextRecognitionService(onDevice: OnDeviceTextRecognitionProvider()).recognise(data, intent: intent)
    }
    let selection = ImageTextSelection()
    private var overlay: ImageTextSelectionOverlay?
    private var task: Task<Void, Never>?
    private var activeGeneration: UUID?
    private var activeItem: ItemID?
    private var completedGeneration: UUID?
    private var run = UUID()
    private var closed = false
    nonisolated(unsafe) private var closeObserver: (any NSObjectProtocol)?

    init(controller: CanvasWindowController) {
        self.controller = controller
        if let window = controller.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
        observeAnnotateMode()
        observeImageGeneration()
        observePhase()
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    var hasSelection: Bool { selection.selectedText != nil && !closed && controller?.session.isAnnotating != true }
    func copy() -> Bool {
        guard hasSelection, let text = selection.selectedText else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    func press(_ point: CGPoint) -> Bool {
        guard isEligible else { clearSelection(); return false }
        let hit = selection.begin(at: point)
        overlay?.needsDisplay = true
        return hit
    }
    func drag(_ point: CGPoint) { selection.drag(to: point); overlay?.needsDisplay = true }
    func release() { overlay?.needsDisplay = true }
    func pointer(_ point: CGPoint) -> Bool { isEligible && selection.containsLine(at: point) }
    func escape() -> Bool {
        guard hasSelection else { return false }
        clearSelection()
        return true
    }
    private func clearSelection() { selection.clear(); overlay?.needsDisplay = true }
    private var isEligible: Bool {
        guard let controller else { return false }
        return !closed && !controller.session.isAnnotating && !controller.canvas.isHidden && !controller.gridShellVisible &&
            controller.canvas.backdropFrame.image != nil && controller.session.imageLoader.presented != nil
    }

    func backdropChanged(_ frame: CanvasBackdropFrame) {
        guard let controller else { return }
        selection.geometry = ImageTextGeometry(transform: frame.transform, imageSize: frame.sourceSize)
        overlay?.needsDisplay = true
        let generation = controller.session.imageLoader.generation
        let item = controller.session.imageLoader.presented?.key.itemID
        guard frame.image != nil, item != nil, !controller.session.isAnnotating, !closed,
              !controller.canvas.isHidden, !controller.gridShellVisible else { cancel(); return }
        if activeGeneration != generation || activeItem != item {
            if activeGeneration != nil || activeItem != nil { cancel() }
            activeGeneration = generation
            activeItem = item
        }
        guard completedGeneration != generation, task == nil else { return }
        let thisRun = run
        task = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.run == thisRun,
                  let controller = self.controller,
                  controller.session.imageLoader.generation == generation,
                  controller.session.imageLoader.presented?.key.itemID == item,
                  !controller.session.isAnnotating,
                  controller.session.imageLoader.phase == .settled ||
                    controller.session.imageLoader.phase == .detailLimited,
                  let image = controller.canvas.backdropFrame.image else {
                if self?.run == thisRun { self?.task = nil }
                return
            }
            do {
                let data = try await ViewerRecogniseTextAdapter.sourceData(image: image)
                try Task.checkCancellation()
                let result = try await self.recognise(data, .selectOnImage)
                guard !Task.isCancelled, self.run == thisRun,
                      controller.session.imageLoader.generation == generation,
                      controller.session.imageLoader.presented?.key.itemID == item,
                      !controller.session.isAnnotating else {
                    if self.run == thisRun { self.task = nil }
                    return
                }
                self.selection.lines = result.lines
                self.completedGeneration = generation
                if !result.lines.isEmpty { self.ensureOverlay() }
                self.overlay?.needsDisplay = true
            } catch { /* Direct selection is silent; explicit recognition reports errors. */ }
            if self.run == thisRun { self.task = nil }
        }
    }

    func cancel() {
        run = UUID()
        task?.cancel(); task = nil
        activeGeneration = nil; activeItem = nil
        completedGeneration = nil
        selection.lines = []
        overlay?.needsDisplay = true
    }
    private func ensureOverlay() {
        guard overlay == nil, let canvas = controller?.canvas else { return }
        let view = ImageTextSelectionOverlay(frame: canvas.bounds)
        view.autoresizingMask = [.width, .height]
        view.selection = selection
        canvas.addSubview(view)
        overlay = view
    }
    private func windowClosed() {
        closed = true
        cancel()
        overlay?.removeFromSuperview(); overlay = nil
    }
    private func observeAnnotateMode() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.session.isAnnotating
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.controller?.session.isAnnotating == true { self.cancel() }
                else if let controller = self.controller { self.backdropChanged(controller.canvas.backdropFrame) }
                self.observeAnnotateMode()
            }
        }
    }
    private func observeImageGeneration() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.session.imageLoader.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.activeGeneration != self.controller?.session.imageLoader.generation { self.cancel() }
                self.observeImageGeneration()
            }
        }
    }
    private func observePhase() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.session.imageLoader.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let controller = self.controller else { return }
                if controller.session.imageLoader.phase == .settled ||
                    controller.session.imageLoader.phase == .detailLimited {
                    self.backdropChanged(controller.canvas.backdropFrame)
                }
                self.observePhase()
            }
        }
    }
}

extension CanvasWindowController {
    func installSelectTextInput() {
        canvas.onTextPress = { [weak self] in self?.selectTextAdapter.press($0) ?? false }
        canvas.onTextDrag = { [weak self] in self?.selectTextAdapter.drag($0) }
        canvas.onTextRelease = { [weak self] in self?.selectTextAdapter.release() }
        canvas.onTextPointer = { [weak self] in self?.selectTextAdapter.pointer($0) ?? false }
        canvas.onTextEscape = { [weak self] in self?.selectTextAdapter.escape() ?? false }
        canvas.onCopyAction = { [weak self] in
            guard let self else { return }
            if !self.selectTextAdapter.copy() { self.copy(nil) }
        }
        canvas.onCanCopy = { [weak self] item in
            guard let self else { return false }
            return self.selectTextAdapter.hasSelection || self.validateMenuItem(item)
        }
    }
}
