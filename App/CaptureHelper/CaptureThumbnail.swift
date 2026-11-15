import AppKit
import MadoApplication
import MadoMacUI

/// Page 38 `capture-thumbnail.html` variant A: .corner right/bottom 20, gap 6; .thumb 240 wide, border 3
/// `--color-panel`, radius 8; image area aspect-fit.
enum CaptureThumbnailLayout {
    static let margin: CGFloat = 20
    static let width: CGFloat = 240
    static let border: CGFloat = 3
    static let radius: CGFloat = 8
    static let gap: CGFloat = 6
    static let imageWidth = width - 2 * border
    /// A very tall Capture is drawn aspect-fit inside a square image area; a very wide one keeps a usable height.
    static let maxImageHeight = imageWidth
    static let minImageHeight: CGFloat = 24
    static let statusHeight: CGFloat = 21
    /// Room around the corner for the shadow.
    static let shadowInset: CGFloat = 16

    static func imageHeight(forPixelWidth width: Int, pixelHeight height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return maxImageHeight }
        let fitted = (imageWidth * CGFloat(height) / CGFloat(width)).rounded()
        return min(maxImageHeight, max(minImageHeight, fitted))
    }

    static func cornerFrame(visibleFrame: NSRect, imageHeight: CGFloat) -> NSRect {
        let height = imageHeight + 2 * border + gap + statusHeight
        return NSRect(x: visibleFrame.maxX - margin - width, y: visibleFrame.minY + margin, width: width, height: height)
    }
}

/// The thumbnail sits on the display that was captured.
enum CaptureThumbnailPlacement {
    static func visibleFrame(for request: CaptureRequest?, screens: [(id: UInt32, visible: NSRect)],
                             pointer: NSPoint) -> NSRect {
        var displayID: UInt32?
        switch request?.target {
        case let .region(_, id, _, _)?: displayID = id
        case let .fullScreen(id)?: displayID = id
        case .window?, nil: displayID = nil
        }
        if let displayID, let screen = screens.first(where: { $0.id == displayID }) { return screen.visible }
        return screens.first { $0.visible.contains(pointer) }?.visible ?? screens.first?.visible ?? .zero
    }

    @MainActor static func screens() -> [(id: UInt32, visible: NSRect)] {
        NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { (id: $0.uint32Value, visible: screen.visibleFrame) }
        }
    }
}

enum CaptureThumbnailText {
    static func status(_ status: CaptureThumbnailStatus, localize: (String) -> String) -> String {
        switch status {
        case let .saved(folder, clipboard):
            let key: String
            switch clipboard {
            case .copied: key = "Saved to %@ · Copied"
            case .notCopied: key = "Saved to %@"
            case .copyFailed: key = "Saved to %@ · Couldn't copy"
            }
            return String(format: localize(key), folder)
        case let .notSaved(clipboard, saveFailed):
            switch (clipboard, saveFailed) {
            case (.copied, false): return localize("Only on the clipboard · Not saved")
            case (.notCopied, false): return localize("Not saved · Not copied")
            case (.copyFailed, false): return localize("Not saved · Couldn't copy")
            case (.copied, true): return localize("Couldn't save · Copied")
            case (.notCopied, true): return localize("Couldn't save · Not copied")
            case (.copyFailed, true): return localize("Couldn't save · Couldn't copy")
            }
        }
    }

    static func title(_ action: CaptureThumbnailAction) -> String {
        switch action {
        case .save: "Save"
        case .copy: "Copy"
        case .moveToTrash: "Move to Trash"
        }
    }

    static func symbol(_ action: CaptureThumbnailAction) -> String {
        switch action {
        case .save: "square.and.arrow.down"
        case .copy: "doc.on.doc"
        case .moveToTrash: "trash"
        }
    }
}

/// Drag-out: the file once the Capture is saved, the PNG data before (#684 AC-4). The source only offers
/// `.copy`, so a drop never moves the original.
enum CaptureThumbnailDrag {
    static func writer(for payload: CaptureDragPayload) -> NSPasteboardWriting {
        switch payload {
        case let .file(url):
            return url as NSURL
        case let .png(png):
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            return item
        }
    }
}

struct PasteboardCaptureClipboard: CaptureClipboardPort {
    let name: NSPasteboard.Name
    init(name: NSPasteboard.Name = .general) { self.name = name }

    func writePNG(_ png: Data) async -> Bool {
        await MainActor.run {
            let pasteboard = NSPasteboard(name: name)
            pasteboard.clearContents()
            return pasteboard.setData(png, forType: .png)
        }
    }
}

/// Delete is always Move to Trash; Mado never deletes a Capture permanently (#684 AC-3).
struct FileManagerCaptureTrash: CaptureTrashPort {
    let trash: @Sendable (URL) throws -> Void
    init(trash: @escaping @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) { self.trash = trash }

    func moveToTrash(_ url: URL) async throws { try trash(url) }
}

/// Never key and never main: the frontmost app keeps its focus while the thumbnail is up.
final class CaptureThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ThumbnailButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class CaptureThumbnailView: NSView, NSDraggingSource {
    var onHover: (Bool) -> Void = { _ in }
    var onAction: (CaptureThumbnailAction) -> Void = { _ in }
    var onClose: () -> Void = {}
    var payload: () -> CaptureDragPayload = { .png(Data()) }

    private let shadowHost = NSView()
    private let thumb = NSView()
    private let image = NSView()
    private let overlay = NSView()
    private let closeButton = ThumbnailButton(title: "", target: nil, action: nil)
    private let status = NSVisualEffectView()
    private let statusText = NSTextField(labelWithString: "")
    private var buttons: [ThumbnailButton] = []
    private var trackingArea: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private let localize: (String) -> String
    private var hovered = false

    var dragOperationMask: NSDragOperation { .copy }

    init(localize: @escaping (String) -> String) {
        self.localize = localize
        super.init(frame: .zero)
        wantsLayer = true
        shadowHost.wantsLayer = true
        shadowHost.layer?.cornerRadius = CaptureThumbnailLayout.radius
        shadowHost.layer?.shadowOpacity = 1
        shadowHost.layer?.shadowRadius = 12
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(shadowHost)
        thumb.wantsLayer = true
        thumb.layer?.borderWidth = CaptureThumbnailLayout.border
        thumb.layer?.cornerRadius = CaptureThumbnailLayout.radius
        thumb.layer?.masksToBounds = true
        thumb.setAccessibilityIdentifier("capture.thumbnail.thumb")
        thumb.setAccessibilityElement(true)
        thumb.setAccessibilityRole(.image)
        addSubview(thumb)
        image.wantsLayer = true
        image.layer?.contentsGravity = .resizeAspect
        thumb.addSubview(image)
        overlay.wantsLayer = true
        // Design 38 .overlay: a fixed black 55 % scrim over the image (no token).
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        overlay.isHidden = true
        overlay.setAccessibilityIdentifier("capture.thumbnail.overlay")
        thumb.addSubview(overlay)
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 10
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.toolTip = localize("Close Thumbnail")
        closeButton.setAccessibilityLabel(localize("Close Thumbnail"))
        closeButton.setAccessibilityIdentifier("capture.thumbnail.close")
        closeButton.isHidden = true
        thumb.addSubview(closeButton)
        status.material = .popover
        status.blendingMode = .behindWindow
        status.state = .active
        status.wantsLayer = true
        status.layer?.cornerRadius = DesignMetrics.radii["inner"]!
        status.layer?.masksToBounds = true
        status.setAccessibilityIdentifier("capture.thumbnail.status")
        statusText.font = DesignMetrics.font("uiSmall")
        statusText.textColor = DesignColor.textPrimary.nsColor
        statusText.setAccessibilityIdentifier("capture.thumbnail.status.text")
        status.addSubview(statusText)
        addSubview(status)
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let panel = DesignColor.popoverBackground.nsColor.cgColor
            thumb.layer?.borderColor = panel
            thumb.layer?.backgroundColor = panel
            shadowHost.layer?.backgroundColor = panel
            shadowHost.layer?.shadowColor = NSColor.black.withAlphaComponent(0.16).cgColor
            buttons.first { $0.identifier?.rawValue == CaptureThumbnailAction.save.rawValue }?
                .layer?.backgroundColor = DesignColor.primaryFill.nsColor.cgColor
        }
    }

    /// Lays out the corner (thumbnail above the status line) inside `bounds`, inset for the shadow.
    func render(png: Data, imageHeight: CGFloat, actions: [CaptureThumbnailAction], statusLine: String,
                accessibilityName: String) {
        let inset = CaptureThumbnailLayout.shadowInset
        let thumbHeight = imageHeight + 2 * CaptureThumbnailLayout.border
        let statusY = inset
        statusText.stringValue = statusLine
        statusText.sizeToFit()
        let statusWidth = min(CaptureThumbnailLayout.width, statusText.frame.width.rounded(.up) + 16)
        status.frame = NSRect(x: inset + CaptureThumbnailLayout.width - statusWidth, y: statusY,
                              width: statusWidth, height: CaptureThumbnailLayout.statusHeight)
        statusText.frame = NSRect(x: 8, y: (CaptureThumbnailLayout.statusHeight - statusText.frame.height) / 2,
                                  width: statusWidth - 16, height: statusText.frame.height)
        let thumbFrame = NSRect(x: inset, y: statusY + CaptureThumbnailLayout.statusHeight + CaptureThumbnailLayout.gap,
                                width: CaptureThumbnailLayout.width, height: thumbHeight)
        thumb.frame = thumbFrame
        shadowHost.frame = thumbFrame
        thumb.setAccessibilityLabel(accessibilityName)
        thumb.toolTip = localize("Drag to another app")
        let border = CaptureThumbnailLayout.border
        image.frame = NSRect(x: border, y: border, width: CaptureThumbnailLayout.imageWidth, height: imageHeight)
        image.layer?.contents = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        overlay.frame = thumb.bounds
        closeButton.frame = NSRect(x: 4, y: thumbHeight - 24, width: 20, height: 20)
        layoutButtons(actions, in: thumb.bounds)
        installTrackingArea(thumbFrame.union(status.frame))
        applyColors()
        setHovered(hovered)
    }

    private func layoutButtons(_ actions: [CaptureThumbnailAction], in bounds: NSRect) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action in
            let button = ThumbnailButton(title: localize(CaptureThumbnailText.title(action)), target: self,
                                         action: #selector(performAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.setAccessibilityIdentifier("capture.thumbnail.action.\(action.rawValue)")
            button.isBordered = false
            button.font = DesignMetrics.font("uiSmall")
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: DesignMetrics.font("uiSmall"), .foregroundColor: NSColor.white])
            button.image = NSImage(systemSymbolName: CaptureThumbnailText.symbol(action), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            button.imagePosition = .imageAbove
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.cornerRadius = DesignMetrics.radii["control"]!
            overlay.addSubview(button)
            return button
        }
        let columns = 3, padding: CGFloat = 6, rowGap: CGFloat = 4, rowHeight: CGFloat = 40
        let columnWidth = (bounds.width - 2 * padding) / CGFloat(columns)
        let rows = (buttons.count + columns - 1) / columns
        let total = CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowGap
        let top = (bounds.height + total) / 2
        for (index, button) in buttons.enumerated() {
            let row = index / columns, column = index % columns
            button.frame = NSRect(x: padding + CGFloat(column) * columnWidth,
                                  y: top - CGFloat(row + 1) * rowHeight - CGFloat(row) * rowGap,
                                  width: columnWidth, height: rowHeight)
        }
    }

    private func installTrackingArea(_ rect: NSRect) {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    func setHovered(_ hovered: Bool) {
        self.hovered = hovered
        overlay.isHidden = !hovered
        closeButton.isHidden = !hovered
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: CaptureThumbnailDrag.writer(for: payload()))
        let snapshot = NSImage(size: thumb.bounds.size)
        if let contents = image.layer?.contents { snapshot.addRepresentation(NSBitmapImageRep(cgImage: contents as! CGImage)) }
        item.setDraggingFrame(thumb.frame, contents: snapshot)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    @objc private func performAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = CaptureThumbnailAction(rawValue: raw) else { return }
        onAction(action)
    }

    @objc private func close(_ sender: NSButton) { onClose() }
}

@MainActor final class CaptureThumbnailController {
    let model: CaptureThumbnailModel
    let panel: CaptureThumbnailPanel
    let view: NSView
    private(set) var lifetime: CaptureThumbnailLifetime
    private(set) var isOpen = false
    private(set) var cornerFrame: NSRect = .zero
    var onClose: (() -> Void)?
    private let thumbnailView: CaptureThumbnailView
    private let visibleFrame: NSRect
    private let now: () -> Date
    private let localize: (String) -> String
    private let startsTimer: Bool
    private var timer: Timer?
    private var trashFailed = false

    init(model: CaptureThumbnailModel, visibleFrame: NSRect, now: @escaping () -> Date = Date.init,
         localize: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) },
         startsTimer: Bool = true) {
        self.model = model
        self.visibleFrame = visibleFrame
        self.now = now
        self.localize = localize
        self.startsTimer = startsTimer
        lifetime = CaptureThumbnailLifetime(shownAt: now())
        panel = CaptureThumbnailPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if #available(macOS 26, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        thumbnailView = CaptureThumbnailView(localize: localize)
        view = thumbnailView
        panel.contentView = thumbnailView
        thumbnailView.onHover = { [weak self] inside in inside ? self?.pointerEntered() : self?.pointerExited() }
        thumbnailView.onAction = { [weak self] action in self?.perform(action) }
        thumbnailView.onClose = { [weak self] in self?.close() }
        thumbnailView.payload = { [weak self] in self?.dragPayload ?? .png(Data()) }
    }

    var dragPayload: CaptureDragPayload { model.state.dragPayload }

    func show() {
        lifetime = CaptureThumbnailLifetime(shownAt: now())
        isOpen = true
        render()
        panel.orderFrontRegardless()
        if startsTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    func tick() {
        guard isOpen else { return }
        render()
        if lifetime.isExpired(at: now()) { close() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        model.close()
        onClose?()
    }

    func pointerEntered() {
        lifetime.pointerEntered()
        thumbnailView.setHovered(true)
    }

    func pointerExited() {
        lifetime.pointerExited(at: now())
        thumbnailView.setHovered(false)
    }

    private func perform(_ action: CaptureThumbnailAction) {
        Task { @MainActor in
            switch action {
            case .copy: await model.copy()
            case .save: try? await model.save()
            case .moveToTrash:
                do {
                    try await model.moveToTrash()
                    trashFailed = false
                } catch {
                    trashFailed = true
                }
            }
            if model.isClosed { close() } else { render() }
        }
    }

    private func render() {
        let state = model.state
        let pixels = NSBitmapImageRep(data: state.png)
        let imageHeight = CaptureThumbnailLayout.imageHeight(forPixelWidth: pixels?.pixelsWide ?? 0,
                                                             pixelHeight: pixels?.pixelsHigh ?? 0)
        cornerFrame = CaptureThumbnailLayout.cornerFrame(visibleFrame: visibleFrame, imageHeight: imageHeight)
        let inset = CaptureThumbnailLayout.shadowInset
        panel.setFrame(cornerFrame.insetBy(dx: -inset, dy: -inset), display: false)
        thumbnailView.frame = NSRect(origin: .zero, size: panel.frame.size)
        let line = trashFailed ? localize("Couldn't move to the Trash")
            : CaptureThumbnailText.status(state.status, localize: localize)
        let name = String(format: localize("Capture Thumbnail %@"), state.savedURL?.lastPathComponent ?? "")
        thumbnailView.render(png: state.png, imageHeight: imageHeight, actions: state.actions, statusLine: line,
                             accessibilityName: name)
    }
}

/// At most one Capture Thumbnail: a new Capture replaces the one on screen.
@MainActor final class CaptureThumbnailPresenter {
    private var current: CaptureThumbnailController?

    var windows: [NSWindow] { current.map { [$0.panel] } ?? [] }

    func present(_ controller: CaptureThumbnailController) {
        current?.close()
        current = controller
        controller.onClose = { [weak self, weak controller] in
            if let self, self.current === controller { self.current = nil }
        }
        controller.show()
    }

    func dismiss() { current?.close() }
}

/// Every helper window a Capture must keep out of its image: the bar, its status panel and the thumbnail.
enum CaptureHelperWindows {
    @MainActor static func request(target: CaptureRequest.Target, bar: NSWindow?, status: NSWindow?,
                                   thumbnails: CaptureThumbnailPresenter, overlays: [NSWindow]) -> CaptureRequest {
        CaptureRequestFromWindows.make(target: target, bars: [bar, status].compactMap { $0 } + thumbnails.windows,
                                       overlays: overlays)
    }
}
