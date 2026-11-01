import AppKit
import SwiftUI
import PicseeCore
import PicseeApplication

struct ChromeToolFace: View {
    let motionPolicy: MotionPolicy?
    let session: ViewerSession
    let id: CommandID
    let enabled: Bool
    let state: ComponentState
    init(session: ViewerSession, id: CommandID, interaction: ComponentState = [], motionPolicy: MotionPolicy? = nil) {
        self.motionPolicy = motionPolicy
        self.session = session; self.id = id; enabled = session.isEnabled(id)
        state = interaction.union(enabled ? [] : .disabled)
    }
    @Environment(\.colorScheme) private var scheme
    var command: CommandID { id == .actualPixels && session.zoomMode == .actualPixels ? .fit : id }
    var customZoom: Double? { if case .custom(let value) = session.zoomMode { value } else { nil } }
    func activate() { CommandRouter().route(command, from: .button, to: session) }
    var body: some View {
        MotionPolicyContent(policy: motionPolicy) {
            if id == .actualPixels {
                ScaleIndicator(actualPixels: session.zoomMode == .actualPixels, customZoom: customZoom, state: state, theme: scheme == .dark ? .dark : .light, input: .live, action: activate)
                    .disabled(!enabled)
            } else {
                IconCommandButton(symbol: Self.symbol(id), state: state,
                    theme: scheme == .dark ? .dark : .light, input: .live, action: activate)
            }
        }
    }
    static func symbol(_ id: CommandID) -> DesignSymbol {
        switch id {
        case .open: .folder
        case .inspector: .info
        case .previous: .previous
        case .next: .next
        case .zoomOut: .zoomOut
        default: .zoomIn
        }
    }
}

/// Native input/focus shell around the shared live design component.
public final class ChromeToolView: NSView {
    private var session: ViewerSession?
    private var id: CommandID = .open
    private var face: NSHostingView<ChromeToolFace>?
    private var motionPolicy: MotionPolicy?
    public var command: CommandID { id == .actualPixels && session?.zoomMode == .actualPixels ? .fit : id }
    convenience init(frame: NSRect, session: ViewerSession, command: CommandID, motionPolicy: MotionPolicy? = nil) {
        self.init(frame: frame)
        self.motionPolicy = motionPolicy
        self.session = session; id = command
        let face = NSHostingView(rootView: ChromeToolFace(session: session, id: command, motionPolicy: motionPolicy))
        face.frame = bounds; face.autoresizingMask = [.width, .height]
        addSubview(face); self.face = face
        face.setAccessibilityHidden(true)
        setAccessibilityChildren([])
        focusRingType = .exterior
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityIdentifier("command.\(command.rawValue).button")
        setAccessibilityLabel(command == .open ? String(localized: "Open…") : command == .actualPixels ? String(localized: "Zoom mode") : String(localized: String.LocalizationValue(ChromeToolFace.symbol(command).label)))
        toolTip = commandTooltip
    }
    var commandTooltip: String {
        let label = String(localized: String.LocalizationValue(command == .open ? "Open…" : command == .fit ? "Fit window" : command == .actualPixels ? "Actual Pixels" : ChromeToolFace.symbol(command).label))
        let hint = command == .previous ? "←" : command == .next ? "→" : command.usesCommand ? "⌘" + command.defaultKey.uppercased() : command.defaultKey
        return label + " (\(hint))"
    }
    public override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && session?.isEnabled(command) == true }
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
        guard id == .actualPixels, let face else { return super.accessibilityValue() }
        return ScaleIndicator(actualPixels: face.rootView.session.zoomMode == .actualPixels,
            customZoom: face.rootView.customZoom, action: activate).label
    }
    public func activate() {
        face?.rootView.activate()
    }
    func refresh() {
        toolTip = commandTooltip
        if let session { face?.rootView = ChromeToolFace(session: session, id: id,
            interaction: ComponentInput.live.state([], focused: focused, pressed: pressed), motionPolicy: motionPolicy) }
        setAccessibilityEnabled(session?.isEnabled(command) == true)
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
    private let fileLabel = NSTextField(labelWithString: "")
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
        let commands: [[CommandID]] = [[.open, .inspector], [.previous, .next], [.zoomOut, .actualPixels, .zoomIn]]
        let frames = [NSRect(x: 16, y: 14, width: 72, height: 38),
            NSRect(x: bounds.midX - 37, y: 14, width: 74, height: 38),
            NSRect(x: bounds.width - 212, y: 14, width: 196, height: 38)]
        let positions: [[CGFloat]] = [[5, 37], [5, 39], [5, 37, 161]]
        for index in 0..<3 {
            let group = ChromeFloatingGroupView(frame: frames[index])
            group.wantsLayer = true; group.layer?.cornerRadius = DesignMetrics.radii["control"]!
            addSubview(group); groups.append(group)
            for (offset, command) in commands[index].enumerated() {
                let tool = ChromeToolView(frame: NSRect(x: positions[index][offset], y: 5,
                    width: command == .actualPixels ? 122 : 30, height: 28), session: session, command: command, motionPolicy: motionPolicy)
                group.addSubview(tool); tools.append(tool)
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
        let labelWidth = ceil(fileLabel.cell!.cellSize.width)
        let width = min(260, max(74, min(bounds.width - 32, labelWidth + 74)))
        let rightX = bounds.width - 212
        let singleRow = bounds.width >= width + 316
        let sideBySide = rightX >= 96
        groups[0].frame = NSRect(x: 16, y: sideBySide ? 14 : 106, width: 72, height: 38)
        groups[2].frame = NSRect(x: rightX, y: 14, width: 196, height: 38)
        let centeredX = (bounds.width - width) / 2
        let centerX = singleRow ? min(max(centeredX, 96), rightX - 8 - width) : centeredX
        groups[1].frame = NSRect(x: centerX, y: singleRow ? 14 : 60, width: width, height: 38)
        tools[3].setFrameOrigin(NSPoint(x: width - 35, y: 5))
        fileLabel.frame = NSRect(x: 37, y: 10, width: max(0, width - 74), height: 18)
        metadataSortNotice.sizeToFit()
        metadataSortNotice.frame.origin = NSPoint(x: max(12, bounds.maxX - metadataSortNotice.frame.width - 20), y: 64)
        for group in groups {
            group.layer?.shadowPath = CGPath(roundedRect: group.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        }
        needsDisplay = true
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
        let loop: [NSView] = [canvas] + enabled
        for index in loop.indices { loop[index].nextKeyView = loop[(index + 1) % loop.count] }
    }
    public func refresh(filename: String? = nil, position: String? = nil) {
        self.filename = filename; self.position = position
        fileLabel.stringValue = [filename, position].compactMap { $0 }.joined(separator: " · ")
        arrangeGroups()
        fileLabel.setAccessibilityValue(filename ?? "")
        for tool in tools { tool.refresh() }
        updateAccessibilityChildren(visible: shown)
        relinkKeyViews()
    }
}
