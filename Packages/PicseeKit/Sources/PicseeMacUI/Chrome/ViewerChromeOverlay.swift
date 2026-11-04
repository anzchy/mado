import AppKit
import SwiftUI
import PicseeCore
import PicseeApplication

/// What a viewer bottom tool does: a base command, a viewer intent (#444: 侧栏 / 返回网格), or the 更多 menu.
public enum ChromeToolKind: Equatable, Sendable {
    case command(CommandID), intent(ViewerChromeIntent), more
}

struct ChromeToolFace: View {
    let motionPolicy: MotionPolicy?
    let session: ViewerSession
    let kind: ChromeToolKind
    let enabled: Bool
    let state: ComponentState
    let action: () -> Void
    init(session: ViewerSession, kind: ChromeToolKind, enabled: Bool, interaction: ComponentState = [],
         motionPolicy: MotionPolicy? = nil, action: @escaping () -> Void) {
        self.motionPolicy = motionPolicy
        self.session = session; self.kind = kind; self.enabled = enabled; self.action = action
        var state = interaction.union(enabled ? [] : .disabled)
        if kind == .intent(.toggleSidebar), session.isViewerSidebarShown { state.insert(.selected) }
        self.state = state
    }
    @Environment(\.colorScheme) private var scheme
    var customZoom: Double? { if case .custom(let value) = session.zoomMode { value } else { nil } }
    var body: some View {
        MotionPolicyContent(policy: motionPolicy) {
            if kind == .command(.actualPixels) {
                ScaleIndicator(actualPixels: session.zoomMode == .actualPixels, customZoom: customZoom, state: state, theme: scheme == .dark ? .dark : .light, input: .live, action: action)
                    .disabled(!enabled)
            } else {
                IconCommandButton(symbol: Self.symbol(kind), state: state,
                    theme: scheme == .dark ? .dark : .light, input: .live, action: action)
            }
        }
    }
    static func symbol(_ kind: ChromeToolKind) -> DesignSymbol {
        switch kind {
        case .intent(.toggleSidebar): .sidebar
        case .intent(.returnToGrid): .grid
        case .more: .more
        case .command(.open): .folder
        case .command(.inspector): .info
        case .command(.previous): .previous
        case .command(.next): .next
        case .command(.zoomOut): .zoomOut
        case .command: .zoomIn
        }
    }
}

/// #444: presents a viewer pod menu (the zoom mode and 更多 menus). The App installs NSMenu's modal pop-up; the
/// package never starts real menu tracking, which would block the main actor in tests.
@MainActor public protocol ChromeMenuPresenting: AnyObject {
    func present(_ menu: NSMenu, from view: NSView)
}

/// Native input/focus shell around the shared live design component.
public final class ChromeToolView: NSView {
    private var session: ViewerSession!
    public private(set) var kind: ChromeToolKind = .command(.open)
    private var face: NSHostingView<ChromeToolFace>?
    private var motionPolicy: MotionPolicy?
    weak var overlay: ViewerChromeOverlay?
    /// The base command this tool routes, or nil for a viewer intent or the 更多 menu.
    public var command: CommandID? { if case .command(let id) = kind { id } else { nil } }
    public var intent: ViewerChromeIntent? { if case .intent(let intent) = kind { intent } else { nil } }
    public var symbolName: String { ChromeToolFace.symbol(kind).name }
    /// page 14's select chevron: about 9×6, centred 94 pt in and halfway up the 100×26 缩放模式 control.
    private let chevron = NSImageView()
    public var chevronFrame: NSRect { kind == .command(.actualPixels) ? chevron.frame : .zero }
    convenience init(frame: NSRect, session: ViewerSession, kind: ChromeToolKind, motionPolicy: MotionPolicy? = nil) {
        self.init(frame: frame)
        self.motionPolicy = motionPolicy
        self.session = session; self.kind = kind
        let face = NSHostingView(rootView: makeFace())
        face.frame = bounds; face.autoresizingMask = [.width, .height]
        addSubview(face); self.face = face
        face.setAccessibilityHidden(true)
        if kind == .command(.actualPixels) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            chevron.imageScaling = .scaleAxesIndependently
            chevron.frame = NSRect(x: 89.5, y: 10, width: 9, height: 6)
            chevron.setAccessibilityElement(false)
            addSubview(chevron)
            updateChevronColor()
        }
        setAccessibilityChildren([])
        focusRingType = .exterior
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityIdentifier(Self.identifier(kind))
        refreshLabels()
    }
    static func identifier(_ kind: ChromeToolKind) -> String {
        switch kind {
        case .command(let id): "command.\(id.rawValue).button"
        case .intent(.toggleSidebar): "chrome.sidebar.button"
        case .intent(.returnToGrid): "chrome.returnToGrid.button"
        case .more: "chrome.more.button"
        }
    }
    private func makeFace(interaction: ComponentState = []) -> ChromeToolFace {
        ChromeToolFace(session: session, kind: kind, enabled: isEnabled, interaction: interaction,
                       motionPolicy: motionPolicy) { [weak self] in self?.activate() }
    }
    /// Sidebar shown state; it drives the label, the tooltip and the pressed look (page 14 aria-pressed).
    private var sidebarShown: Bool { kind == .intent(.toggleSidebar) && session?.isViewerSidebarShown == true }
    var label: String {
        switch kind {
        case .command(.open): String(localized: "Open…")
        case .command(.actualPixels): String(localized: "Zoom mode")
        case .command: String(localized: String.LocalizationValue(ChromeToolFace.symbol(kind).label))
        case .intent(.toggleSidebar): String(localized: sidebarShown ? "Hide sidebar" : "Show sidebar")
        case .intent(.returnToGrid): String(localized: "Return to grid")
        case .more: String(localized: "More browse actions")
        }
    }
    var commandTooltip: String {
        switch kind {
        case .command(.actualPixels), .more: return label
        case .intent(.toggleSidebar): return label + " (⌃⌘S)"
        case .intent(.returnToGrid): return label + " (Esc)"
        case .command(let id):
            let hint = id == .previous ? "←" : id == .next ? "→" : id.usesCommand ? "⌘" + id.defaultKey.uppercased() : id.defaultKey
            return label + " (\(hint))"
        }
    }
    private func refreshLabels() {
        setAccessibilityLabel(label)
        toolTip = commandTooltip
    }
    /// Each kind follows its own Session predicate, read afresh whenever the overlay refreshes.
    public var isEnabled: Bool {
        guard let session else { return false }
        switch kind {
        case .command(let id): return session.isEnabled(id)
        case .intent(.returnToGrid): return session.canReturnToSource
        case .intent(.toggleSidebar): return session.canToggleViewerSidebar
        // 更多 is a control only while a menu can open: the App's provider and presenter (fix round 1).
        case .more: return overlay?.moreMenuProvider != nil && overlay?.menuPresenter != nil
        }
    }
    public override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        !isHiddenOrHasHiddenAncestor && frame.contains(point) ? self : nil
    }
    weak var pointerCanvas: NSView?
    private var pressed = false
    private var focused = false
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func mouseDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return }
        pressed = true; refresh()
        session?.setChromeInteraction(.pointerPress, active: true)
    }
    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; refresh()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
        session?.setChromeInteraction(.pointerPress, active: false)
        if window?.firstResponder === self, let pointerCanvas {
            session?.updateFocus(.canvas)
            window?.makeFirstResponder(pointerCanvas)
        }
    }
    public override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        focused = true; refresh()
        session?.updateFocus(.tools); needsDisplay = true
        return true
    }
    public override func resignFirstResponder() -> Bool { focused = false; refresh(); needsDisplay = true; return true }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { bounds.fill() }
    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: session?.tab(reverse: event.modifierFlags.contains(.shift))
        case 49: activate()
        case 53:
            if let session { CommandRouter().route(.escape, from: .key, to: session) }
        default: break
        }
    }
    public override func accessibilityPerformPress() -> Bool {
        guard acceptsFirstResponder else { return false }
        activate()
        return true
    }
    public override func accessibilityValue() -> Any? {
        switch kind {
        case .command(.actualPixels):
            guard let session else { return super.accessibilityValue() }
            let custom: Double? = if case .custom(let value) = session.zoomMode { value } else { nil }
            return ScaleIndicator(actualPixels: session.zoomMode == .actualPixels, customZoom: custom, action: activate).label
        case .intent(.toggleSidebar): return NSNumber(value: sidebarShown ? 1 : 0)
        default: return super.accessibilityValue()
        }
    }
    public func activate() {
        guard let session, isEnabled else { return }
        switch kind {
        case .command(.actualPixels): overlay?.presentZoomModeMenu(from: self)
        case .command(let id): CommandRouter().route(id, from: .button, to: session)
        case .intent(let intent): session.perform(intent: intent)
        case .more: overlay?.presentMoreMenu(from: self)
        }
        overlay?.refreshTools()
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChevronColor()
    }
    private func updateChevronColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chevron.contentTintColor = DesignColor.textPrimary.nsColor
        }
        chevron.alphaValue = isEnabled ? 1 : 0.4
    }
    func refresh() {
        refreshLabels()
        face?.rootView = makeFace(interaction: ComponentInput.live.state([], focused: focused, pressed: pressed))
        setAccessibilityEnabled(isEnabled)
        updateChevronColor()
    }
}

private final class ChromeFloatingGroupView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 5.75, yRadius: 5.75)
            DesignColor.popoverBackground.nsColor.setFill()
            outline.fill()
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            DesignColor.textPrimary.nsColor.withAlphaComponent(dark ? 0.16 : 0.12).setStroke()
            outline.lineWidth = 0.5
            outline.stroke()
        }
    }
}

public final class ViewerChromeOverlay: NSView {
    private var session: ViewerSession?
    public private(set) var tools: [ChromeToolView] = []
    public private(set) var groups: [NSView] = []
    public private(set) var filename: String?
    public private(set) var position: String?
    /// #444: the zoom mode and 更多 menus pop up through this; nil leaves both menus closed.
    public var menuPresenter: (any ChromeMenuPresenting)? { didSet { refreshTools() } }
    /// #444: builds the 更多浏览操作 menu (the App's implemented items); nil leaves 更多 inert.
    public var moreMenuProvider: (() -> NSMenu?)? { didSet { refreshTools() } }
    /// #444: key views after the tools in the viewer's loop (the folder sidebar when it is shown).
    public var trailingKeyViews: () -> [NSView] = { [] }
    private weak var nextTool: ChromeToolView?
    private let fileLabel = NSTextField(labelWithString: "")
    private var showsImagePosition = false
    let metadataSortNotice = GridSortNoticeLabel(labelWithString: String(localized: "Sort unfinished"))
    private var displayedMetadataSortState: MetadataSortState = .idle
    /// #331: the Home (status `.empty`, pinned page 21) shows only its centre. Opt-in, so only the App window hides.
    public private(set) var hidesOnHome = false
    private var requestedVisible = true
    private var isHome = false
    public convenience init(frame: NSRect, session: ViewerSession, motionPolicy: MotionPolicy? = nil,
                            hidesOnHome: Bool = false) {
        self.init(frame: frame)
        self.session = session
        self.hidesOnHome = hidesOnHome
        // page 14 (#444): 侧栏 / 返回网格 / 更多 | ← name → | − 缩放模式 +. Pods 104 and 174 wide; the 缩放模式
        // select is 100×26 at y 6, the buttons 30×28 at y 5.
        let kinds: [[ChromeToolKind]] = [[.intent(.toggleSidebar), .intent(.returnToGrid), .more],
            [.command(.previous), .command(.next)], [.command(.zoomOut), .command(.actualPixels), .command(.zoomIn)]]
        let frames = [NSRect(x: 16, y: 14, width: 104, height: 38),
            NSRect(x: bounds.midX - 37, y: 14, width: 74, height: 38),
            NSRect(x: bounds.width - 190, y: 14, width: 174, height: 38)]
        let positions: [[CGFloat]] = [[5, 37, 69], [5, 39], [5, 37, 139]]
        for index in 0..<3 {
            let group = ChromeFloatingGroupView(frame: frames[index])
            group.wantsLayer = true; group.layer?.cornerRadius = DesignMetrics.radii["control"]!
            addSubview(group); groups.append(group)
            for (offset, kind) in kinds[index].enumerated() {
                let zoomMode = kind == .command(.actualPixels)
                let tool = ChromeToolView(frame: NSRect(x: positions[index][offset], y: zoomMode ? 6 : 5,
                    width: zoomMode ? 100 : 30, height: zoomMode ? 26 : 28), session: session, kind: kind, motionPolicy: motionPolicy)
                tool.overlay = self
                group.addSubview(tool); tools.append(tool)
                if kind == .command(.next) { nextTool = tool }
            }
        }
        fileLabel.frame = NSRect(x: 37, y: 10, width: 0, height: 18)
        fileLabel.setAccessibilityElement(true); fileLabel.setAccessibilityRole(.staticText)
        fileLabel.setAccessibilityIdentifier("chrome.filename")
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.font = DesignMetrics.font("uiSmall")
        groups[1].addSubview(fileLabel)
        metadataSortNotice.isHidden = true
        metadataSortNotice.font = .systemFont(ofSize: 12, weight: .medium)
        metadataSortNotice.textColor = .secondaryLabelColor
        metadataSortNotice.wantsLayer = true
        addSubview(metadataSortNotice)
        arrangeGroups()
        updateGroupColors()
        refresh()
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGroupColors()
    }
    private func updateGroupColors() {
        needsDisplay = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            metadataSortNotice.layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
            for group in groups {
                guard let layer = group.layer else { continue }
                layer.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
                layer.shadowColor = dark ? NSColor.black.cgColor : DesignColor.textPrimary.nsColor.cgColor
                layer.shadowOpacity = dark ? 0.45 : 0.08
                layer.shadowRadius = 12
                layer.shadowOffset = CGSize(width: 0, height: -8)
                layer.masksToBounds = false
                group.needsDisplay = true
            }
        }
    }
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        arrangeGroups()
    }
    private func arrangeGroups() {
        guard groups.count == 3 else { return }
        // Measure the actual label, then cap it for middle truncation. The side groups
        // keep their 30×28 command targets when compact windows require wrapping.
        // NSTextFieldCell includes its text drawing inset; raw NSString width does not.
        // Page14's filename/position label has 8 pt inline padding; NSTextFieldCell includes 4 pt per side.
        let extraPadding: CGFloat = showsImagePosition ? 8 : 0
        let labelWidth = ceil(fileLabel.cell!.cellSize.width) + extraPadding
        let width = min(260, max(74, min(bounds.width - 32, labelWidth + 74)))
        // The zoom pod keeps a 16 pt right inset; the side pods stay 8 pt apart from the centre pod or wrap.
        let rightX = bounds.width - 190
        let singleRow = bounds.width >= width + 326
        let sideBySide = rightX >= 128
        groups[0].frame = NSRect(x: 16, y: sideBySide ? 14 : 106, width: 104, height: 38)
        groups[2].frame = NSRect(x: rightX, y: 14, width: 174, height: 38)
        let centeredX = (bounds.width - width) / 2
        let centerX = singleRow ? min(max(centeredX, 128), rightX - 8 - width) : centeredX
        groups[1].frame = NSRect(x: centerX, y: singleRow ? 14 : 60, width: width, height: 38)
        nextTool?.setFrameOrigin(NSPoint(x: width - 35, y: 5))
        fileLabel.frame = NSRect(x: 37 + extraPadding / 2, y: 10,
            width: max(0, width - 74 - extraPadding), height: 18)
        metadataSortNotice.sizeToFit()
        metadataSortNotice.frame.origin = NSPoint(x: max(12, bounds.maxX - metadataSortNotice.frame.width - 20), y: 64)
        for group in groups {
            group.layer?.shadowPath = CGPath(roundedRect: group.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        }
        needsDisplay = true
    }
    /// The 缩放模式 menu lists page 14's two modes; each routes its own existing command (VIEW-01 / VIEW-02).
    func makeZoomModeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let mode = session?.zoomMode
        for (title, command, current) in [(String(localized: "Fit window"), CommandID.fit, mode == .fit),
                                          ("1:1 · 100%", .actualPixels, mode == .actualPixels)] {
            let item = NSMenuItem(title: title, action: #selector(chooseZoomMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.state = current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    @objc private func chooseZoomMode(_ item: NSMenuItem) {
        guard let session, let raw = item.representedObject as? String, let command = CommandID(rawValue: raw) else { return }
        CommandRouter().route(command, from: .button, to: session)
        refreshTools()
    }
    func presentZoomModeMenu(from tool: ChromeToolView) { present(makeZoomModeMenu(), from: tool) }
    func presentMoreMenu(from tool: ChromeToolView) {
        guard let menu = moreMenuProvider?() else { return }
        present(menu, from: tool)
    }
    /// The tools never hide under an open menu (CHROME-03): the menu lock holds while it tracks.
    private func present(_ menu: NSMenu, from tool: ChromeToolView) {
        guard let menuPresenter else { return }
        session?.setChromeMenuOpen(true)
        menuPresenter.present(menu, from: tool)
        session?.setChromeMenuOpen(false)
        refreshTools()
    }
    func refreshTools() {
        for tool in tools { tool.refresh() }
        updateAccessibilityChildren(visible: shown)
        relinkKeyViews()
    }
    public func setMetadataSortState(_ state: MetadataSortState) {
        guard displayedMetadataSortState != state else { return }
        displayedMetadataSortState = state
        let visible = state == .pending || state == .incomplete
        let label = String(localized: state == .incomplete ? "Sort metadata unavailable" : "Sort unfinished")
        metadataSortNotice.stringValue = label
        metadataSortNotice.setAccessibilityLabel(label)
        metadataSortNotice.setAccessibilityIdentifier(state == .incomplete ? "folder.sort.incomplete" : "folder.sort.pending")
        metadataSortNotice.isHidden = !visible
        metadataSortNotice.setAccessibilityHidden(!visible)
        arrangeGroups()
    }
    public static let edgeBandHeight: CGFloat = 32
    public func pointerMoved(_ point: NSPoint) {
        let region: ChromePointerRegion = !bounds.contains(point) ? .outside : point.y < Self.edgeBandHeight ? .bottom : point.y >= bounds.height - Self.edgeBandHeight ? .top : .canvas
        session?.pointerMoved(in: region)
        session?.setChromeInteraction(.pointerHover, active: groups.contains { !$0.isHidden && $0.frame.contains(point) })
        for tool in tools { tool.toolTip = tool.commandTooltip }
    }
    public func focusTool(reverse: Bool, entering: Bool) -> Bool {
        let enabled = tools.filter(\.acceptsFirstResponder)
        let target: ChromeToolView?
        if entering { target = reverse ? enabled.last : enabled.first }
        else if let index = enabled.firstIndex(where: { $0 === window?.firstResponder }) {
            let next = index + (reverse ? -1 : 1)
            target = enabled.indices.contains(next) ? enabled[next] : nil
        } else { target = nil }
        guard let target else { return false }
        return window?.makeFirstResponder(target) == true
    }
    private weak var canvas: NSView?
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for group in groups.reversed() where !group.isHidden && group.frame.contains(local) {
            return group.hitTest(local)
        }
        return nil
    }
    /// The state host reports whether it shows the Home; the session's own chrome request is kept for leaving it.
    public func setHome(_ home: Bool) {
        guard isHome != home else { return }
        isHome = home
        applyToolsVisible()
    }
    public func setToolsVisible(_ visible: Bool) {
        requestedVisible = visible
        applyToolsVisible()
    }
    private var shown: Bool { requestedVisible && !(hidesOnHome && isHome) }
    private var returningFocus = false
    private func applyToolsVisible() {
        // The Home hides without the session's focus lock, so a focused control hands focus to the canvas before
        // anything hides (hiding it first would pass focus along the key chain to another tool). The focus update
        // re-syncs the chrome and lands here again; that pass leaves the hiding to this one.
        guard !returningFocus else { return }
        if !shown, let canvas, let focused = window?.firstResponder as? ChromeToolView, tools.contains(focused) {
            returningFocus = true
            session?.updateFocus(.canvas)
            window?.makeFirstResponder(canvas)
            returningFocus = false
        }
        let visible = shown
        for view in groups + tools { view.isHidden = !visible }
        needsDisplay = true
        updateAccessibilityChildren(visible: visible)
        relinkKeyViews()
    }
    /// On the Home the state host owns the key loop (its Choose Folder… button); the overlay only drops a canvas
    /// link into its own hidden tools.
    private func relinkKeyViews() {
        guard let canvas else { return }
        if hidesOnHome && isHome {
            if canvas.nextKeyView is ChromeToolView { canvas.nextKeyView = canvas }
        } else { linkKeyViews(to: canvas) }
    }
    private func updateAccessibilityChildren(visible: Bool) {
        setAccessibilityChildren(visible ? tools + (filename == nil ? [] : [fileLabel]) : [])
    }
    public func linkKeyViews(to canvas: NSView) {
        self.canvas = canvas
        for tool in tools { tool.pointerCanvas = canvas }
        let enabled = tools.filter(\.acceptsFirstResponder)
        let loop: [NSView] = [canvas] + enabled + trailingKeyViews().filter(\.acceptsFirstResponder)
        for index in loop.indices { loop[index].nextKeyView = loop[(index + 1) % loop.count] }
    }
    public func refresh(filename: String? = nil, position: String? = nil) {
        self.filename = filename; self.position = position
        showsImagePosition = false
        if let filename, let position, position.range(of: #"^[0-9]+ / [0-9]+$"#, options: .regularExpression) != nil {
            showsImagePosition = true
            let font = DesignMetrics.font("uiSmall")
            let text = NSMutableAttributedString(string: filename, attributes: [.font: font])
            let spaces = ("  " as NSString).size(withAttributes: [.font: font]).width
            // Keep the pin's two-space text contract while drawing its 12 pt flex gap.
            text.append(NSAttributedString(string: "  ", attributes: [.font: font, .kern: (12 - spaces) / 2]))
            text.append(NSAttributedString(string: position,
                attributes: [.font: DesignMetrics.font("uiSmall", monospaced: true),
                             .foregroundColor: DesignColor.textPrimary.nsColor]))
            // Attributed text needs its own paragraph style; the cell's lineBreakMode
            // alone clips the text before the trailing fraction at the 260 pt pod cap.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let halo = NSShadow()
            halo.shadowColor = DesignColor.popoverBackground.nsColor
            halo.shadowOffset = .zero
            halo.shadowBlurRadius = 1
            text.addAttributes([.foregroundColor: DesignColor.textPrimary.nsColor,
                                .shadow: halo, .paragraphStyle: paragraph],
                               range: NSRange(location: 0, length: text.length))
            fileLabel.attributedStringValue = text
        } else {
            fileLabel.stringValue = [filename, position].compactMap { $0 }.joined(separator: " · ")
        }
        arrangeGroups()
        fileLabel.setAccessibilityValue(fileLabel.stringValue)
        for tool in tools { tool.refresh() }
        updateAccessibilityChildren(visible: shown)
        relinkKeyViews()
    }
}
