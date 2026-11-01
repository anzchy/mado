import AppKit
import SwiftUI
import Observation
import PicseeCore
import PicseeApplication

@MainActor final class ReadingProgressView: NSView {
    let dividerLayer = CAShapeLayer()
    let accentLayer = CAShapeLayer()
    /// Spins around the ring's centre. The view's own layer pivots on its corner and AppKit resets its geometry.
    private let spinLayer = CALayer()
    let notificationCenter: NotificationCenter
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    nonisolated(unsafe) private var reduceMotionObserver: NSObjectProtocol?

    init(frame frameRect: NSRect, notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
        super.init(frame: frameRect)
        wantsLayer = true
        dividerLayer.fillColor = NSColor.clear.cgColor
        accentLayer.fillColor = NSColor.clear.cgColor
        dividerLayer.lineWidth = 2
        accentLayer.lineWidth = 2
        accentLayer.lineCap = .butt
        layer?.addSublayer(spinLayer)
        spinLayer.addSublayer(dividerLayer)
        spinLayer.addSublayer(accentLayer)
        setAccessibilityRole(.progressIndicator)
        refreshAppearance()
        reduceMotionObserver = notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }
    deinit {
        if let reduceMotionObserver {
            notificationCenter.removeObserver(reduceMotionObserver)
        }
    }
    required init?(coder: NSCoder) { nil }
    var rotationLayer: CALayer? { spinLayer }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: 1, dy: 1)
        dividerLayer.path = CGPath(ellipseIn: inset, transform: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 1
        let segment = CGMutablePath()
        segment.addArc(center: center, radius: radius, startAngle: .pi / 4, endAngle: 3 * .pi / 4, clockwise: false)
        accentLayer.path = segment
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.bounds = bounds
        spinLayer.position = center
        dividerLayer.frame = bounds
        accentLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dividerLayer.strokeColor = DesignColor.divider.nsColor.cgColor
            accentLayer.strokeColor = DesignColor.accent.nsColor.cgColor
        }
    }

    func start() {
        layout()
        spinLayer.removeAnimation(forKey: "picsee.reading.rotation")
        guard !reduceMotion() else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1
        rotation.repeatCount = .infinity
        spinLayer.add(rotation, forKey: "picsee.reading.rotation")
    }
}

private struct StateText: View {
    let lines: [String]
    let isLoading: Bool
    let isNotice: Bool
    var body: some View {
        VStack(spacing: 12) {
            if isLoading { IndeterminateProgressRow(label: lines[0]) }
            else {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line).font(Font(DesignMetrics.font(isNotice ? "uiSmall" : index == 0 ? "title" : "ui")))
                        .foregroundStyle(index == 0 ? DesignColor.textPrimary.color : DesignColor.textSecondary.color)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native state surface; decisions arrive as Application-owned image status.
public final class ViewerStateHost: NSView {
    public private(set) var buttons: [NSButton] = []
    public private(set) var textLines: [String] = []
    public private(set) var showsProgress = false
    /// 「读取失败」 (24F-A) on the folder-entry reading surface (#238).
    public private(set) var readFailedView: ReadFailedStateView?
    private let readFailedPage = ReadFailedStateView()
    public var onRetry: (() -> Void)?
    public var onCancelFolderReading: (() -> Void)?
    private weak var keyCanvas: NSView?
    private weak var keyChrome: ViewerChromeOverlay?
    private var displayedStatus: ViewerImageStatus?
    private var displayedNextEnabled = false
    private var composedState: ViewerImageStatus?
    private var stateIcon: NSImageView?
    private var stateLabels: [NSTextField] = []
    private var firstLaunch: FirstLaunchView?
    private var readingViews: (progress: NSView, heading: NSTextField, subtitle: NSTextField, cancel: NSButton)?
    public func setFirstLaunchDragActive(_ active: Bool) { firstLaunch?.setDragActive(active) }
    public func linkKeyViews(to canvas: NSView, chrome: ViewerChromeOverlay) {
        keyCanvas = canvas; keyChrome = chrome
        chrome.setHome(displayedStatus == .empty)
        ViewerStateFocus.link(canvas: canvas, state: self, chrome: chrome)
    }
    private var session: ViewerSession?
    private var tracking = false
    /// Which window surface this host sits on; GridViewerPresentation owns it. The grid surface never shows a state.
    public enum Surface: Sendable { case viewer, gridReading, grid }
    public var surface: Surface = .viewer {
        didSet { applyVisibility(); if heldReading, surface != .gridReading { refresh() } }
    }
    /// The App shows the Reading State on the reading surface before the scan starts, while the Session still reads
    /// `.empty`. Rebuilding the Home in that gap restarted its wall drift (#316), so the Reading State holds there.
    private var heldReading = false
    /// Page 22 on the viewer surface (owner decision C, #137); GridShellView mirrors its page here.
    public let emptyFolderView = EmptyFolderStateView()
    private var emptyFolderPage: EmptyFolderPage?
    public func setEmptyFolderPage(_ page: EmptyFolderPage?) {
        emptyFolderPage = page
        if displayedStatus == .emptyFolder { showEmptyFolderPage() }
    }
    /// Shows the bare page until its content arrives, so the generic state never covers an open empty folder.
    private func showEmptyFolderPage() {
        let page = emptyFolderPage ?? EmptyFolderPage(subfolders: [], recents: [], includeSubfoldersAvailable: false)
        emptyFolderView.display(subfolders: page.subfolders, recents: page.recents,
                                includeSubfoldersAvailable: page.includeSubfoldersAvailable)
        buttons = emptyFolderView.keyViews.compactMap { $0 as? NSButton }
        if let keyCanvas, let keyChrome { ViewerStateFocus.link(canvas: keyCanvas, state: self, chrome: keyChrome) }
    }
    private func applyVisibility() {
        isHidden = surface == .grid || displayedStatus == .showing
        setAccessibilityHidden(isHidden)
    }

    public convenience init(frame: NSRect, session: ViewerSession) {
        self.init(frame: frame)
        self.session = session
        refresh()
    }
    public func refresh() {
        guard let session else { return }
        if !tracking {
            tracking = true
            withObservationTracking {
                displaySessionStatus(session)
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.tracking = false; self?.refresh() }
            }
        } else { displaySessionStatus(session) }
    }
    private func displaySessionStatus(_ session: ViewerSession) {
        let status = session.imageStatus
        guard surface != .gridReading || status != .empty || displayedStatus != .readingFolder else { heldReading = true; return }
        display(status, nextEnabled: session.isEnabled(.next))
    }
    public func display(_ status: ViewerImageStatus, nextEnabled: Bool = false) {
        heldReading = false
        guard displayedStatus != status || displayedNextEnabled != nextEnabled else { return }
        displayedStatus = status; displayedNextEnabled = nextEnabled
        // #331: the chrome hides on the Home before the deferred relink, so the loop keeps Choose Folder….
        keyChrome?.setHome(status == .empty)
        if let focused = window?.firstResponder as? NSView,
           buttons.contains(where: { focused === $0 || focused.isDescendant(of: $0) }), let keyCanvas {
            session?.updateFocus(.canvas)
            window?.makeFirstResponder(keyCanvas)
        }
        defer {
            if let keyCanvas, let keyChrome { ViewerStateFocus.link(canvas: keyCanvas, state: self, chrome: keyChrome) }
        }
        setAccessibilityChildren([])
        applyVisibility()
        // B4's open button sits inside FirstLaunchView, out of reach of the subview sweep below. The empty-folder
        // page keeps its own controls between visits, so only the outgoing first-launch button is retired here.
        if firstLaunch != nil {
            buttons.forEach {
                $0.isHidden = true; $0.setAccessibilityHidden(true)
                $0.isEnabled = false; $0.setAccessibilityEnabled(false); $0.nextKeyView = nil
            }
        }
        subviews.forEach {
            $0.isHidden = true; $0.setAccessibilityHidden(true); $0.nextKeyView = nil
            if let button = $0 as? NSButton { button.isEnabled = false; button.setAccessibilityEnabled(false) }
            $0.removeFromSuperview()
        }
        buttons = []; textLines = []; showsProgress = false
        composedState = nil; stateIcon = nil; stateLabels = []; firstLaunch = nil; readingViews = nil; readFailedView = nil
        var actions: [(String, String)] = []
        var failure = false
        let notice = status == .detailLimited
        switch status {
        case .empty:
            textLines = [String(localized: "Drop a photo folder here"),
                         String(localized: "or press ⌘O"), String(localized: "Folder"),
                         String(localized: "One or more images"), String(localized: "Common image formats")]
            actions = [(String(localized: "Choose Folder…"), "state.open")]
        case .loading(let name):
            showsProgress = true
            textLines = [String(format: String(localized: "Opening %@…"), name)]
            actions = [(String(localized: "Cancel"), "state.cancel")]
        case .readingFolder:
            // Page 24 uses the canvas surface; keep the prior image intact underneath for Cancel.
            let surface = NSBox(frame: bounds)
            surface.boxType = .custom; surface.borderType = .noBorder
            surface.titlePosition = .noTitle; surface.cornerRadius = 0
            surface.fillColor = DesignColor.canvasBackground.nsColor
            surface.autoresizingMask = [.width, .height]
            surface.setAccessibilityElement(false)
            addSubview(surface)
            showsProgress = true
            textLines = [String(localized: "Reading Folder…"),
                String(localized: "Looking for images to browse. Please wait.")]
            let progress = ReadingProgressView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            progress.start()
            progress.setAccessibilityIdentifier("state.folder-progress")
            progress.setAccessibilityElement(true)
            progress.setAccessibilityLabel(textLines[0])
            let heading = NSTextField(labelWithString: textLines[0])
            heading.font = .systemFont(ofSize: 16, weight: .medium)
            heading.textColor = DesignColor.textPrimary.nsColor
            heading.alignment = .center
            heading.setAccessibilityIdentifier("state.folder-title")
            let subtitle = NSTextField(labelWithString: textLines[1])
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = DesignColor.textSecondary.nsColor
            subtitle.alignment = .center
            subtitle.setAccessibilityIdentifier("state.folder-subtitle")
            let cancel = ViewerStateButton(title: String(localized: "Cancel Reading"), target: self, action: #selector(activate(_:)))
            cancel.session = session
            cancel.isBordered = false
            cancel.focusRingType = .exterior
            cancel.contentTintColor = DesignColor.selectionText.nsColor
            cancel.attributedTitle = NSAttributedString(string: cancel.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: DesignColor.selectionText.nsColor,
            ])
            cancel.identifier = NSUserInterfaceItemIdentifier("state.cancel-folder")
            cancel.setAccessibilityIdentifier("state.cancel-folder")
            cancel.setAccessibilityLabel(String(localized: "Cancel Reading"))
            [progress, heading, subtitle, cancel].forEach { addSubview($0) }
            readingViews = (progress, heading, subtitle, cancel)
            buttons = [cancel]; setAccessibilityChildren([progress, heading, subtitle, cancel])
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        case .folderScanFailed(let reason, let folder):
            if surface != .gridReading {
                failure = true
                let count = session?.folderScan?.sourceSnapshot?.navigationEntries.count ?? 0
                textLines = [String(localized: "Unable to finish reading folder"),
                    String(localized: String.LocalizationValue(reason)),
                    String(format: String(localized: "Images found before scan stopped: %lld"), Int64(count))]
                actions = [(String(localized: "Retry"), "state.retry-folder")]
                break
            }
            // 24F-A is folder-entry only: no reason and no partial count (#238).
            let text = ReadFailedStateText(title: String(format: String(localized: "Couldn't finish reading “%@”"), folder),
                detail: String(localized: "Reading stopped partway. To avoid showing an incomplete list, the images found so far are hidden."),
                retry: String(localized: "Retry"), chooseOther: String(localized: "Choose Another Folder…"))
            let page = readFailedPage
            page.onRetry = { [weak self] in self?.session?.retryFolderScan(); self?.refresh() }
            page.onChooseOtherFolder = { [weak self] in
                guard let session = self?.session else { return }
                CommandRouter().route(.open, from: .button, to: session)
            }
            page.frame = bounds
            page.autoresizingMask = [.width, .height]
            page.isHidden = false; page.setAccessibilityHidden(false)
            page.display(text)
            addSubview(page)
            readFailedView = page
            textLines = [text.title, text.detail]
            buttons = page.buttons
            setAccessibilityChildren([page])
            page.layoutSubtreeIfNeeded()
            return
        case .noMatches:
            textLines = [String(localized: "No Images Match This Filter"),
                         String(localized: "Choose another extension or clear the filter.")]
            actions = [(String(localized: "Clear Filter"), "state.clear-filter")]
        case .failed(let kind, let name):
            failure = true
            textLines = [String(localized: "Unable to read this image"), name,
                String(localized: String.LocalizationValue(kind.messageKey))]
            actions = [(String(localized: "Retry"), "state.retry")]
            if nextEnabled { actions.append((String(localized: "Next"), "state.next")) }
        case .detailLimited: textLines = [String(localized: "Showing reduced detail")]
        case .emptyFolder:
            emptyFolderView.frame = bounds
            emptyFolderView.autoresizingMask = [.width, .height]
            emptyFolderView.isHidden = false; emptyFolderView.setAccessibilityHidden(false)
            addSubview(emptyFolderView)
            setAccessibilityChildren([emptyFolderView])
            showEmptyFolderPage()
            return
        case .showing: return
        }
        if case .empty = status {
            let button = ViewerStateButton(title: actions[0].0, target: self, action: #selector(activate(_:)))
            button.session = session
            button.bezelStyle = .rounded; button.focusRingType = .exterior
            button.identifier = NSUserInterfaceItemIdentifier("state.open")
            button.setAccessibilityIdentifier("state.open")
            let launch = FirstLaunchView(frame: bounds, openButton: button)
            addSubview(launch)
            firstLaunch = launch; buttons = [button]
            setAccessibilityChildren(launch.semanticViews)
            return
        }
        if failure {
            composeState(status, actions: actions)
            return
        }
        let text = NSHostingView(rootView: StateText(lines: textLines, isLoading: showsProgress,
            isNotice: notice))
        let center = max(160, bounds.midY)
        text.frame = NSRect(x: 16, y: notice ? bounds.height - 84 : center,
            width: max(0, bounds.width - 32), height: notice ? 32 : failure ? 160 : 80)
        text.autoresizingMask = notice ? [.width, .minYMargin] : [.width, .minYMargin, .maxYMargin]
        addSubview(text)
        let width: CGFloat = actions.count > 1 ? 80 : 180
        let total = CGFloat(actions.count) * width + CGFloat(max(0, actions.count - 1)) * 12
        for (index, action) in actions.enumerated() {
            let button = ViewerStateButton(title: action.0, target: self, action: #selector(activate(_:)))
            button.session = session
            button.bezelStyle = .rounded; button.focusRingType = .exterior
            button.identifier = NSUserInterfaceItemIdentifier(action.1)
            button.setAccessibilityIdentifier(action.1)
            button.frame = NSRect(x: (bounds.width - total) / 2 + CGFloat(index) * (width + 12),
                y: center - 44, width: width, height: 32)
            button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            addSubview(button); buttons.append(button)
        }
        setAccessibilityChildren([text as NSView] + buttons)
    }

    private func composeState(_ status: ViewerImageStatus, actions: [(String, String)]) {
        composedState = status
        let failure: Bool
        switch status {
        case .failed, .folderScanFailed: failure = true
        default: failure = false
        }
        let iconLabel = Self.stateIconLabel(failure: failure)
        let image = NSImageView(image: NSImage(systemSymbolName: failure
            ? "exclamationmark.triangle" : DesignSymbol.folder.name,
            accessibilityDescription: iconLabel)!)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        image.imageScaling = .scaleProportionallyDown
        image.setAccessibilityIdentifier("state.icon")
        image.setAccessibilityRole(.image)
        image.setAccessibilityLabel(iconLabel)
        if !failure { image.setAccessibilityElement(false) }
        addSubview(image); stateIcon = image
        for (index, line) in textLines.enumerated() {
            let field = NSTextField(labelWithString: line)
            field.font = index == 0 ? .systemFont(ofSize: 16, weight: .medium) : DesignMetrics.font("ui")
            field.textColor = failure && index == 2 ? DesignColor.errorText.nsColor :
                index == 0 ? DesignColor.textPrimary.nsColor : DesignColor.textSecondary.nsColor
            field.alignment = .center
            field.cell?.wraps = true
            field.cell?.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
            let id = index == 0 ? "state.heading" : failure
                ? (index == 1 ? "state.filename" : "state.reason")
                : (index == 1 ? "state.description" : "state.drop-hint")
            field.setAccessibilityIdentifier(id)
            field.setAccessibilityRole(.staticText)
            field.setAccessibilityLabel(line)
            addSubview(field); stateLabels.append(field)
        }
        for action in actions {
            let button = ViewerStateButton(title: action.0, target: self, action: #selector(activate(_:)))
            button.session = session
            button.bezelStyle = .rounded; button.focusRingType = .exterior
            button.identifier = NSUserInterfaceItemIdentifier(action.1)
            button.setAccessibilityIdentifier(action.1)
            addSubview(button); buttons.append(button)
        }
        setAccessibilityChildren([image] + stateLabels + buttons)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    static func stateIconLabel(failure: Bool, bundle: Bundle = .main, locale: Locale? = nil) -> String {
        if let locale {
            let localizedBundle = bundle.path(forResource: locale.identifier, ofType: "lproj")
                .flatMap(Bundle.init(path:)) ?? bundle
            return localizedBundle.localizedString(forKey: failure ? "Unreadable image" : "Open folder",
                                                   value: nil, table: nil)
        }
        return failure
            ? String(localized: "Unreadable image", bundle: bundle)
            : String(localized: "Open folder", bundle: bundle)
    }

    /// folder-loading.html `.empty-state` in `.grid-scroll` (padding 16 top, 30 bottom): ring 28 + 8, h2 18 + 23,
    /// p 9 + 22.1, `.mock-actions` 18 then `.text-button` 8 + 35, centred again whenever the host moves.
    private func layoutReading(_ views: (progress: NSView, heading: NSTextField, subtitle: NSTextField, cancel: NSButton)) {
        let groupHeight: CGFloat = 28 + 8 + 18 + 23 + 9 + 22.1 + 18 + 8 + 35
        let groupTop = (16 + (bounds.height - 46) / 2 - groupHeight / 2).rounded()
        func y(fromTop offset: CGFloat, height: CGFloat) -> CGFloat { bounds.height - groupTop - offset - height }
        func centred(_ field: NSTextField, lineTop: CGFloat, lineHeight: CGFloat) {
            let height = ceil(field.intrinsicContentSize.height)
            field.frame = NSRect(x: 16, y: y(fromTop: lineTop + (lineHeight - height) / 2, height: height).rounded(),
                                 width: max(0, bounds.width - 32), height: height)
        }
        views.progress.frame = NSRect(x: (bounds.midX - 14).rounded(), y: y(fromTop: 0, height: 28),
                                      width: 28, height: 28)
        centred(views.heading, lineTop: 54, lineHeight: 23)
        centred(views.subtitle, lineTop: 86, lineHeight: 22.1)
        let cancelWidth = max(32, ceil((views.cancel.intrinsicContentSize.width + 16) / 2) * 2)
        views.cancel.frame = NSRect(x: (bounds.midX - cancelWidth / 2).rounded(),
                                    y: y(fromTop: 134.1, height: 35).rounded(), width: cancelWidth, height: 35)
    }

    /// A sidebar resize moves the host synchronously; keep the reading stack centred before the next layout pass.
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if let readingViews { layoutReading(readingViews) }
    }

    public override func layout() {
        super.layout()
        if let readingViews { layoutReading(readingViews); return }
        guard composedState != nil, let icon = stateIcon else { return }
        let available = max(0, bounds.width - 32)
        let textWidth = min(640, available)
        func measure(_ field: NSTextField, width: CGFloat) -> CGFloat {
            let rect = (field.stringValue as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: field.font!])
            return ceil(rect.height) + 2
        }
        let heading = stateLabels[0], description = stateLabels[1]
        let headingHeight = measure(heading, width: textWidth)
        let descriptionHeight = measure(description, width: textWidth)
        let reasonHeight = measure(stateLabels[2], width: textWidth)
        let buttonWidth: CGFloat = 80
        let buttonHeight: CGFloat = 32
        let contentHeight: CGFloat = 32 + 18 + headingHeight + 9 + descriptionHeight + 9 + reasonHeight + 18 + buttonHeight
        var top = bounds.midY + contentHeight / 2
        icon.frame = NSRect(x: bounds.midX - 16, y: top - 32, width: 32, height: 32)
        top -= 32 + 18
        heading.frame = NSRect(x: bounds.midX - textWidth / 2, y: top - headingHeight,
                               width: textWidth, height: headingHeight)
        top -= headingHeight + 9
        description.frame = NSRect(x: bounds.midX - textWidth / 2, y: top - descriptionHeight,
                                   width: textWidth, height: descriptionHeight)
        top -= descriptionHeight
        top -= 9
        stateLabels[2].frame = NSRect(x: bounds.midX - textWidth / 2, y: top - reasonHeight,
                                      width: textWidth, height: reasonHeight)
        top -= reasonHeight
        top -= 18
        let gap: CGFloat = 16
        let total = CGFloat(buttons.count) * buttonWidth + CGFloat(max(0, buttons.count - 1)) * gap
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: bounds.midX - total / 2 + CGFloat(index) * (buttonWidth + gap),
                                  y: top - buttonHeight, width: buttonWidth, height: buttonHeight)
        }
    }
    @objc private func activate(_ sender: NSButton) {
        guard !isHiddenOrHasHiddenAncestor, sender.isEnabled, !sender.isHiddenOrHasHiddenAncestor,
              buttons.contains(where: { $0 === sender }), let session else { return }
        switch sender.identifier?.rawValue {
        case "state.cancel": session.cancelImageOpening(); refresh()
        case "state.cancel-folder":
            if let onCancelFolderReading { onCancelFolderReading() }
            else { session.cancelFolderReading() }
            refresh()
        case "state.clear-filter":
            var conditions = session.folderConditions
            conditions.selectedExtensions = nil
            session.setFolderConditions(conditions)
            refresh()
        case "state.retry": onRetry?()
        case "state.retry-folder": session.retryFolderScan(); refresh()
        case "state.next": CommandRouter().route(.next, from: .button, to: session)
        default: CommandRouter().route(.open, from: .button, to: session)
        }
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        if emptyFolderView.superview === self { return emptyFolderView.hitTest(local) }
        return buttons.first { button in
            guard !button.isHidden, let parent = button.superview else { return false }
            return button.frame.contains(parent.convert(local, from: self))
        }
    }
}
