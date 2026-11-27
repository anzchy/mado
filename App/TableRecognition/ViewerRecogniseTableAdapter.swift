import AppKit
import MadoApplication
import MadoCore
import MadoInfrastructure

/// View › 识别表格… on the viewer's image (#874): the consent sheet naming the real host, the working sheet with
/// Cancel, and the result panel. One adapter per viewer window; the flow model owns the rules.
///
/// Setup needed, Cloud Recognition off, and failures show one plain "nothing was sent / nothing was copied" alert
/// for now; their own dialogs and next steps are #877 (T8) and #876 (T7).
@MainActor final class ViewerRecogniseTableAdapter {
    typealias FlowFactory = @MainActor (any TableClipboardWriting, @escaping @MainActor () -> Void) -> RecogniseTableFlow
    weak var controller: CanvasWindowController?
    var pasteboard: NSPasteboard = .general
    /// The App's settings, keychain, transport and consent store; tests inject fakes.
    var makeFlow: FlowFactory = { clipboard, onChange in
        RecogniseTableFlow(settings: CloudRecognitionAppServices.tableConfiguration,
                           credentials: CloudRecognitionAppServices.tableKeys,
                           transport: CloudRecognitionAppServices.tableTransport, clipboard: clipboard,
                           recordConsent: { host in
                               await CloudRecognitionAppServices.tablePreferences.setConsent(true, forHost: host)
                           }, onChange: onChange)
    }
    var presentConsent: @MainActor (NSWindow?, NSAlert, @escaping @MainActor (Bool) -> Void) -> Void = { window, alert, answer in
        guard let window else { answer(alert.runModal() == .alertFirstButtonReturn); return }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
        }
    }
    /// Shows the working sheet; `onCancel` runs only when the user clicks Cancel, not when the sheet is ended.
    var presentWorking: @MainActor (NSWindow?, NSAlert, @escaping @MainActor () -> Void) -> Void = { window, alert, onCancel in
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { MainActor.assumeIsolated { onCancel() } }
        }
    }
    var dismissWorking: @MainActor (NSWindow?, NSAlert) -> Void = { window, alert in
        guard let window, alert.window.sheetParent === window else { return }
        window.endSheet(alert.window, returnCode: .abort)
    }
    /// Stub (#874 fix1 WI-1): not called yet.
    var dismissConsent: @MainActor (NSWindow?, NSAlert) -> Void = { window, alert in
        guard let window, alert.window.sheetParent === window else { return }
        window.endSheet(alert.window, returnCode: .abort)
    }
    var presentNotice: @MainActor (NSWindow?, NSAlert) -> Void = { window, alert in
        guard let window else { alert.runModal(); return }
        alert.beginSheetModal(for: window)
    }
    private(set) var flow: RecogniseTableFlow?
    private(set) var panel: RecognisedTablePanel?
    /// The task the run is on now (the checks, then the request after the consent answer); tests await it.
    private(set) var runTask: Task<Void, Never>?
    private var workingAlert: NSAlert?
    private var askingConsent = false
    private var sourceImage: CGImage?
    nonisolated(unsafe) private var closeObserver: (any NSObjectProtocol)?

    init(controller: CanvasWindowController) {
        self.controller = controller
        if let window = controller.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    /// An image is shown, not in Annotate, and no run is waiting for consent or the service.
    var canStart: Bool {
        guard let controller, controller.window != nil, !controller.session.isAnnotating,
              !controller.canvas.isHidden, controller.canvas.backdropFrame.image != nil else { return false }
        return flow?.isBusy != true
    }

    func start() {
        guard canStart, let controller, let image = controller.canvas.backdropFrame.image else { return }
        closePanel(returnFocus: false)
        let sourceSize = controller.canvas.backdropFrame.sourceSize
        let imageLoader = controller.session.imageLoader
        sourceImage = image
        // The image as the file has it: the full-resolution pixels when the canvas shows a reduced preview.
        let source: @Sendable () async throws -> Data = {
            let reduced = image.width != Int(sourceSize.width) || image.height != Int(sourceSize.height)
            let full = reduced
                ? try await imageLoader.recognitionImage(maximumPixelSize: max(Int(sourceSize.width), Int(sourceSize.height)))
                : nil
            return try await ViewerRecogniseTextAdapter.sourceData(image: full ?? image)
        }
        flow?.close()
        let flow = makeFlow(NativeTablePasteboard(pasteboard)) { [weak self] in self?.render() }
        self.flow = flow
        runTask = flow.start(image: source)
    }

    private func render() {
        guard let flow else { return }
        let window = controller?.window
        if case .working = flow.state {} else if let alert = workingAlert {
            workingAlert = nil
            dismissWorking(window, alert)
        }
        switch flow.state {
        case .idle, .cancelled, .preparing:
            break
        case .consent(let host):
            guard !askingConsent else { return }
            askingConsent = true
            presentConsent(window, Self.consentAlert(host: host)) { [weak self, weak flow] granted in
                guard let self, let flow, self.flow === flow else { return }
                self.askingConsent = false
                if let task = flow.answerConsent(granted) { self.runTask = task }
            }
        case .working(let host):
            guard workingAlert == nil else { return }
            let alert = Self.workingAlert(host: host)
            workingAlert = alert
            presentWorking(window, alert) { [weak self, weak flow] in
                guard let self, let flow, self.flow === flow else { return }
                flow.cancel()
            }
        case .result(let result):
            showPanel(result)
        case .setupNeeded, .cloudOff, .notSent, .failed:
            if let alert = Self.noticeAlert(for: flow.state) { presentNotice(window, alert) }
        }
    }

    private func showPanel(_ result: RecognisedTableResult) {
        if let panel { panel.update(result); return }
        let panel = RecognisedTablePanel(result: result, sourceImage: sourceImage)
        panel.onCopy = { [weak self] in self?.flow?.copyTable() }
        panel.onClose = { [weak self] in self?.closePanel(returnFocus: true) }
        self.panel = panel
        if let frame = controller?.window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        _ = panel.makeFirstResponder(panel.copyButton)
    }

    /// Closing the panel ends the run; focus goes back to the image (story 52).
    private func closePanel(returnFocus: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.onCopy = {}
        panel.onClose = {}
        panel.orderOut(nil)
        panel.close()
        flow?.close()
        guard returnFocus, let controller, let window = controller.window else { return }
        window.makeKeyAndOrderFront(nil)
        controller.session.updateFocus(.canvas)
        _ = window.makeFirstResponder(controller.canvas)
    }

    private func windowClosed() {
        flow?.close()
        if let alert = workingAlert { workingAlert = nil; dismissWorking(controller?.window, alert) }
        closePanel(returnFocus: false)
        flow = nil
    }

    // MARK: - Sheets (state 41 `consent`, `working`)

    /// State 41 `consent`. Wording marked owner confirm in the grilling record (decision 3), shipped as written.
    static func consentAlert(host: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: String(localized: "Send this image to %@ to recognise the table?"), host)
        alert.informativeText = String(localized: "The image leaves your Mac, is processed by that service, and its privacy policy applies. You can turn off Cloud Recognition in Settings at any time.")
            + "\n\n" + String(localized: "Consent covers only this server; a different address asks again.")
        alert.addButton(withTitle: String(localized: "Agree and Recognise"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    /// State 41 `working`: the host the image went to, an indeterminate bar, and Cancel.
    static func workingAlert(host: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Recognising table…")
        alert.informativeText = String(format: String(localized: "The image was sent to %@. This usually takes a few seconds to over ten seconds."), host)
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 30, width: 260, height: 12))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        let fine = NSTextField(wrappingLabelWithString: String(localized: "Cancelling doesn't retry automatically; a request already sent may have been charged."))
        fine.font = NSFont.systemFont(ofSize: 11)
        fine.textColor = .secondaryLabelColor
        fine.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        accessory.addSubview(progress)
        accessory.addSubview(fine)
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    /// Stub (#874 fix1 WI-2): the working sheet has no sent line yet.
    static func sentLine(of alert: NSAlert) -> NSTextField? { nil }

    /// Interim plain notices until #877 (setup, off) and #876 (failures) draw their own: each says what was not
    /// sent or not copied, and nothing more.
    static func noticeAlert(for state: RecogniseTableState) -> NSAlert? {
        let message: String
        let detail: String
        switch state {
        case .setupNeeded:
            message = String(localized: "Connect a recognition service first")
            detail = String(localized: "Set up Table Recognition in Settings. No image has been sent.")
        case .cloudOff:
            message = String(localized: "Cloud Recognition is off")
            detail = String(localized: "Turn on Allow Cloud Recognition in Settings to recognise tables. No image has been sent.")
        case .notSent(.imageTooLarge):
            message = String(localized: "This image is too large")
            detail = String(localized: "It is larger than the service allows and was not sent.")
        case .notSent:
            message = String(localized: "Couldn't recognise the table")
            detail = String(localized: "The image was not sent. Nothing was copied.")
        case .failed:
            message = String(localized: "Couldn't recognise the table")
            detail = String(localized: "Nothing was copied. The original image and the clipboard are unchanged.")
        case .idle, .consent, .preparing, .working, .result, .cancelled:
            return nil
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK"))
        return alert
    }
}

extension CanvasWindowController {
    var canRecogniseTableFromMenu: Bool { recogniseTableAdapter.canStart }
    func recogniseTable() { recogniseTableAdapter.start() }
}
