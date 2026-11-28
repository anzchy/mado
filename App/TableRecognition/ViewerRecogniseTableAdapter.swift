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
    /// Ends the consent sheet when the run it asks for is abandoned (the viewer moved to another image).
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
    private var consentSheet: NSAlert?
    private var sourceImage: CGImage?
    /// The image the run started on (#874 fix1 WI-1): the loader generation and the shown item and revision.
    private var runGeneration: UUID?
    private var runKey: RenderKey?
    nonisolated(unsafe) private var closeObserver: (any NSObjectProtocol)?

    init(controller: CanvasWindowController) {
        self.controller = controller
        if let window = controller.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
        observeImageGeneration()
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
        runGeneration = imageLoader.generation
        runKey = imageLoader.presented?.key
        // The file's own image data without its metadata when the service takes it as it is (#874 fix1 WI-5, fix2
        // WI-3); otherwise a PNG of the image as the file has it: the full-resolution pixels when the canvas shows a
        // reduced preview. Neither carries the file's EXIF, GPS, XMP or IPTC.
        let source: @Sendable () async throws -> Data = {
            if let original = await imageLoader.recognitionOriginal(
                    maximumByteCount: TableRecognitionSource.maximumOriginalBytes),
               let payload = TableRecognitionSource.payload(from: original) {
                return payload
            }
            let reduced = image.width != Int(sourceSize.width) || image.height != Int(sourceSize.height)
            let full = reduced
                ? try await imageLoader.recognitionImage(maximumPixelSize: max(Int(sourceSize.width), Int(sourceSize.height)))
                : nil
            return try await ViewerRecogniseTextAdapter.sourceData(image: full ?? image)
        }
        flow?.close()
        consentSheet = nil
        let flow = makeFlow(NativeTablePasteboard(pasteboard)) { [weak self] in self?.render() }
        self.flow = flow
        runTask = flow.start(image: source)
    }

    private func render() {
        guard let flow else { return }
        // Every change of a run checks at once that the viewer still shows the run's image (#874 fix2 WI-2): a
        // change queued before a move to another image (the transport's start, the answer) ends the run instead of
        // showing anything for it. The generation observer alone runs later, after such a change. A result already
        // in its panel stays with its own image, and Copy Table keeps working there (WI-4).
        if panel == nil, flow.state != .idle, !isCurrent {
            flow.close()
            return
        }
        let window = controller?.window
        if !Self.showsWorkingSheet(flow.state), let alert = workingAlert {
            workingAlert = nil
            dismissWorking(window, alert)
        }
        if case .consent = flow.state {} else if let alert = consentSheet {
            consentSheet = nil
            dismissConsent(window, alert)
        }
        switch flow.state {
        case .idle, .cancelled:
            break
        case .consent(let host):
            guard consentSheet == nil else { return }
            let alert = Self.consentAlert(host: host)
            consentSheet = alert
            presentConsent(window, alert) { [weak self, weak flow] granted in
                guard let self, let flow, self.flow === flow else { return }
                if self.consentSheet === alert { self.consentSheet = nil }
                if let task = flow.answerConsent(granted) { self.runTask = task }
            }
        case .preparing, .working:
            // One sheet for the whole run. It says the image was sent only once the service calls the transport
            // (#874 fix1 WI-2); until then it shows the title, the bar and Cancel.
            let alert: NSAlert
            if let workingAlert { alert = workingAlert } else {
                alert = Self.workingAlert()
                workingAlert = alert
                presentWorking(window, alert) { [weak self, weak flow] in
                    guard let self, let flow, self.flow === flow else { return }
                    flow.cancel()
                }
            }
            if case .working(let host) = flow.state { Self.sentLine(of: alert)?.stringValue = Self.sentText(host: host) }
        case .result(let result):
            // A result for an image the viewer has left was dropped above; one already in its panel stays there.
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
        sourceImage = nil
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
        consentSheet = nil
        closePanel(returnFocus: false)
        flow = nil
        sourceImage = nil
    }

    /// The viewer still shows the image the run started on.
    private var isCurrent: Bool {
        guard let loader = controller?.session.imageLoader, loader.generation == runGeneration else { return false }
        let key = loader.presented?.key
        return key?.itemID == runKey?.itemID && key?.revision == runKey?.revision
    }

    /// Moving to another image while a run waits for consent, prepares or sends ends that run: its sheets go and
    /// its answer is dropped (#874 fix1 WI-1). A result already in the panel stays with its own image.
    private func observeImageGeneration() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.session.imageLoader.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let flow = self.flow, flow.isBusy, !self.isCurrent { flow.close() }
                self.observeImageGeneration()
            }
        }
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

    static func showsWorkingSheet(_ state: RecogniseTableState) -> Bool {
        switch state {
        case .preparing, .working: true
        default: false
        }
    }

    static let sentLineIdentifier = NSUserInterfaceItemIdentifier("table.working.sent")

    /// State 41 `working`'s sentence, shown only once the request is with the service.
    static func sentText(host: String) -> String {
        sentText(host: host, format: String(localized: "The image was sent to %@. This usually takes a few seconds to over ten seconds."))
    }

    /// `sentText(host:)` with the sentence `format` of a given language. A host longer than `sentHostLimit`
    /// characters keeps its start and its end with "…" between them, so the sentence fits the line (#874 fix2 WI-5).
    static func sentText(host: String, format: String) -> String { String(format: format, shownHost(host)) }

    static let sentHostLimit = 40

    static func shownHost(_ host: String) -> String {
        guard host.count > sentHostLimit else { return host }
        let head = (sentHostLimit - 1) / 2
        return host.prefix(head) + "…" + host.suffix(sentHostLimit - 1 - head)
    }

    /// The working sheet's "was sent" line: empty until the service calls the transport.
    static func sentLine(of alert: NSAlert) -> NSTextField? {
        alert.accessoryView?.subviews.first { $0.identifier == sentLineIdentifier } as? NSTextField
    }

    /// State 41 `working`: the title, the line that names the host once the image was sent (empty before), an
    /// indeterminate bar, and Cancel. The line has its room from the start, so the sheet does not change size.
    static func workingAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Recognising table…")
        alert.informativeText = ""
        let sent = NSTextField(wrappingLabelWithString: "")
        sent.identifier = sentLineIdentifier
        sent.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sent.frame = NSRect(x: 0, y: 48, width: 260, height: 42)
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 30, width: 260, height: 12))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        let fine = NSTextField(wrappingLabelWithString: String(localized: "Cancelling doesn't retry automatically; a request already sent may have been charged."))
        fine.font = NSFont.systemFont(ofSize: 11)
        fine.textColor = .secondaryLabelColor
        fine.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 90))
        accessory.addSubview(sent)
        accessory.addSubview(progress)
        accessory.addSubview(fine)
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

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
