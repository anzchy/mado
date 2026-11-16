import AppKit
import MadoApplication
import MadoInfrastructure

// #687 slice C: 截图并识别文字 in the Capture helper. The region's image stays in memory, #687b's notice and panel show
// at the captured display's bottom-right corner (page 38 `capture-thumbnail.html`: `.corner` / `.panel` right 20,
// bottom 20), and no thumbnail or file is made.

/// The helper's host window for the notice and panel. Never main, and key only while the editable panel shows, so
/// the frontmost app keeps its focus while the notice is up.
final class CaptureRecogniseTextPanel: NSPanel {
    /// The editable panel is showing; read each time AppKit asks, so a replaced or closed panel gives up key at once.
    var showsEditablePanel: () -> Bool = { false }
    override var canBecomeKey: Bool { showsEditablePanel() }
    override var canBecomeMain: Bool { false }
    /// The notice opens on click only. AppKit hands a window's first key view the focus when it comes on screen; a
    /// focused notice holds off its own 5 s dismissal, which here would never run.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is RecogniseTextNoticeView { return false }
        return super.makeFirstResponder(responder)
    }
}

enum CaptureRecogniseTextLayout {
    /// The window around a surface: the overlay keeps it 20 pt from the window's trailing and bottom edges, so the
    /// window's own trailing and bottom edges are the visible frame's.
    static func windowFrame(surface: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.maxX - surface.width - 40, y: visibleFrame.minY,
               width: surface.width + 40, height: surface.height + 40)
    }
}

/// The notice's wording; the viewer's strings (#687b), injectable so pinned tests can use the zh-Hans catalogue.
struct CaptureRecogniseTextStrings {
    var copied: (Int) -> String
    var noText: String
    var failed: String
    var clipboardMayHaveChanged: String
    var engine: (TextRecognitionEngine) -> String

    static var localized: CaptureRecogniseTextStrings {
        CaptureRecogniseTextStrings(
            copied: { String(localized: "Copied \(Int64($0)) characters") },
            noText: String(localized: "No text found · Clipboard unchanged"),
            failed: String(localized: "Unable to recognise text"),
            clipboardMayHaveChanged: String(localized: "Couldn't copy the text · The clipboard may have changed"),
            engine: { engine in
                switch engine {
                case .onDevice: String(localized: "On-device Recognition")
                case .cloud: String(localized: "Baidu Cloud Recognition")
                }
            })
    }
}

/// At most one recognition at a time: a new `present` replaces the run, its notice and its panel.
@MainActor final class CaptureRecogniseTextPresenter {
    typealias Recognise = @Sendable (Data) async throws -> TextRecognitionResult
    /// On-device Vision only: the helper cannot read Mado's Cloud settings or keychain (Capture-side Cloud is #689).
    static let onDevice: Recognise = { data in
        try await TextRecognitionService(onDevice: OnDeviceTextRecognitionProvider()).recognise(data, intent: .explicit)
    }

    let panel: CaptureRecogniseTextPanel
    let overlay: RecogniseTextOverlay
    /// Created in `init`, so a Capture's exclusion list holds it before the first recognition.
    var windows: [NSWindow] { [panel] }

    private let recognise: Recognise
    private let pasteboard: any TextPasteboardWriting
    private let strings: CaptureRecogniseTextStrings
    private let scheduleConfirmationReset: (@escaping @MainActor () -> Void) -> Void
    private let announce: (String) -> Void
    private var model: RecogniseTextModel?
    private var run = UUID()
    private var announcedRun: UUID?
    private var visibleFrame: NSRect = .zero

    init(recognise: @escaping Recognise = CaptureRecogniseTextPresenter.onDevice,
         pasteboard: any TextPasteboardWriting = NativeTextPasteboard(.general),
         strings: CaptureRecogniseTextStrings = .localized,
         scheduleDismiss: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
         scheduleConfirmationReset: ((@escaping @MainActor () -> Void) -> Void)? = nil,
         announce: ((String) -> Void)? = nil) {
        self.recognise = recognise
        self.pasteboard = pasteboard
        self.strings = strings
        self.scheduleConfirmationReset = scheduleConfirmationReset ?? Self.resetAfterTwoSeconds
        self.announce = announce ?? { message in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        panel = CaptureRecogniseTextPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        // The Capture Thumbnail's behaviour (CaptureThumbnailController).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if #available(macOS 26, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        overlay = scheduleDismiss.map { RecogniseTextOverlay(frame: .zero, scheduleDismiss: $0) } ?? RecogniseTextOverlay(frame: .zero)
        panel.contentView = overlay
        overlay.onDismiss = { [weak self] in self?.model?.dismissNotice() }
        panel.showsEditablePanel = { [weak overlay] in overlay?.panelView != nil }
    }

    private static func resetAfterTwoSeconds(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); action() }
    }

    /// Recognises `png` and copies its text; the notice goes to `visibleFrame`'s bottom-right corner.
    @discardableResult func present(png: Data, visibleFrame: NSRect) -> Task<Void, Never> {
        run = UUID()
        let thisRun = run
        model?.close()
        hide()
        self.visibleFrame = visibleFrame
        let model = RecogniseTextModel(recognise: recognise, pasteboard: pasteboard,
            isCurrent: { [weak self] identity in self?.run == identity },
            onChange: { [weak self] in self?.render(thisRun) },
            scheduleConfirmationReset: scheduleConfirmationReset)
        self.model = model
        return model.start(png, identity: thisRun)
    }

    /// Ends the run (a late result never copies) and takes the notice or panel away.
    func dismiss() {
        run = UUID()
        model?.close()
        model = nil
        hide()
    }

    private func render(_ thisRun: UUID) {
        guard thisRun == run, let model else { return }
        if let text = model.panelText, let engine = model.engine {
            if overlay.panelView == nil {
                overlay.showPanel(text: text, engine: strings.engine(engine),
                    onEdit: { [weak self] in self?.model?.edit($0) },
                    onCopy: { [weak self] in
                        self?.model?.copyEditedText()
                        if let self, let editor = self.overlay.panelView?.textView { _ = self.panel.makeFirstResponder(editor) }
                    },
                    onClose: { [weak self] in self?.model?.closePanel() })
                place(surface: overlay.panelView?.frame.size ?? .zero)
                panel.makeKeyAndOrderFront(nil)
                if let editor = overlay.panelView?.textView { _ = panel.makeFirstResponder(editor) }
            }
            overlay.panelView?.showCopiedConfirmation(model.copiedConfirmation)
            return
        }
        guard let notice = model.notice else { hide(); return }
        guard overlay.noticeView == nil else { return }
        switch notice {
        case .copied(let count, let engine):
            overlay.showNotice(message: strings.copied(count), engine: strings.engine(engine), kind: .success,
                               onOpen: { [weak self] in self?.model?.openPanel() })
        case .noText:
            overlay.showNotice(message: strings.noText, engine: nil, kind: .warning, onOpen: nil)
        case .failed:
            overlay.showNotice(message: strings.failed, engine: nil, kind: .warning, onOpen: nil)
        case .clipboardMayHaveChanged:
            overlay.showNotice(message: strings.clipboardMayHaveChanged, engine: nil, kind: .warning, onOpen: nil)
        }
        guard let view = overlay.noticeView else { return }
        // The helper panel is never key while the notice shows, so its first click must reach the notice.
        view.acceptsFirstClick = true
        place(surface: view.intrinsicContentSize)
        panel.orderFrontRegardless()
        if announcedRun != run, let label = view.accessibilityLabel() {
            announcedRun = run
            announce(label)
        }
    }

    /// Frames the window around `surface` at the corner, then lays the surface out 20 pt in.
    private func place(surface: NSSize) {
        panel.setFrame(CaptureRecogniseTextLayout.windowFrame(surface: surface, visibleFrame: visibleFrame), display: false)
        overlay.frame = NSRect(origin: .zero, size: panel.frame.size)
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        for surface in [overlay.noticeView as NSView?, overlay.panelView].compactMap({ $0 }) {
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
        }
    }

    private func hide() {
        if overlay.noticeView != nil || overlay.panelView != nil { overlay.clear() }
        _ = panel.makeFirstResponder(nil)
        panel.orderOut(nil)
    }
}

/// One 截图并识别文字 Capture: the session's image and the visible frame of the display a thumbnail would use.
enum CaptureRecogniseTextFlow {
    @MainActor static func capture(request: @MainActor () -> CaptureRequest, selectedDisplay: UInt32?,
                                   session: CaptureSession, screens: () -> [CaptureThumbnailPlacement.Screen])
        async throws -> (png: Data, visibleFrame: NSRect) {
        let resolved = request()
        let png = try await session.captureForRecognition(request: resolved)
        let displayID = CaptureThumbnailPlacement.displayID(for: resolved.target, selectedDisplay: selectedDisplay)
        return (png, CaptureThumbnailPlacement.visibleFrame(displayID: displayID, screens: screens()))
    }
}

/// What a selection overlay is for: a Capture, or 截图并识别文字.
enum CaptureSelectionPurpose: Equatable { case capture, recogniseText }

/// What the helper does for each global shortcut.
enum CaptureHelperCommand: Equatable {
    case selectRegion(CaptureSelectionPurpose), selectWindow, captureFullScreen, toggleBar

    static func command(for action: CaptureShortcutAction) -> CaptureHelperCommand {
        switch action {
        case .region: .selectRegion(.capture)
        case .window: .selectWindow
        case .fullScreen: .captureFullScreen
        case .recognizeText: .selectRegion(.recogniseText)
        case .toggleBar: .toggleBar
        }
    }
}

/// A finished selection: captured or recognised by its purpose; cancelled (no target) does nothing.
enum CaptureSelectionOutcome: Equatable {
    case capture, recognise, none

    static func route(purpose: CaptureSelectionPurpose, target: CaptureRequest.Target?) -> CaptureSelectionOutcome {
        guard target != nil else { return .none }
        switch purpose {
        case .capture: return .capture
        case .recogniseText: return .recognise
        }
    }
}
