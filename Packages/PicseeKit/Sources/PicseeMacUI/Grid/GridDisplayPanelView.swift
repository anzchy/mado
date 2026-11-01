import AppKit
import PicseeApplication

@MainActor private final class GridDisplayPanelButton: NSButton {
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}
@MainActor private final class GridDisplayPanelSlider: NSSlider {
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}
@MainActor private final class GridDisplayPanelPopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}

/// Page 15 (grid-display.html `.grid-tools-panel`): Thumbnail Size, Show File Names, Thumbnails. Each action writes
/// the store's current value with one field changed; the shell reflects store changes back through `reflect(_:)`.
@MainActor public final class GridDisplayPanelView: NSView {
    public let titleLabel = NSTextField(labelWithString: String(localized: "Display and Appearance"))
    public let closeButton: NSButton = GridDisplayPanelButton()
    public let sizeSlider: NSSlider = GridDisplayPanelSlider()
    public let namesCheckbox: NSButton = GridDisplayPanelButton(checkboxWithTitle: "", target: nil, action: nil)
    public let fitPopup: NSPopUpButton = GridDisplayPanelPopUp(frame: .zero, pullsDown: false)
    public let rows: [NSView] = [NSView(), NSView(), NSView()]
    public let rowLabels: [NSTextField] = [
        NSTextField(labelWithString: String(localized: "Thumbnail Size")),
        NSTextField(labelWithString: String(localized: "Show File Names")),
        NSTextField(labelWithString: String(localized: "Thumbnails")),
    ]
    /// Close button and Esc.
    public var onClose: (() -> Void)?
    private let preferencesStore: any DisplayPreferencesStore
    // viewer-options.css `.grid-tools-panel` padding 12, `header` margin-bottom 9; `.ds-icon-button` 30×28;
    // `.setting-row` padding 10px 2px, min-height 34, gap 14; range width 110; select max-width 135.
    private static let padding: CGFloat = 12
    private static let headerGap: CGFloat = 9
    private static let rowPadding = (vertical: CGFloat(10), horizontal: CGFloat(2))
    private static let rowMinHeight: CGFloat = 34
    private static let rowGap: CGFloat = 14
    private static let sliderWidth: CGFloat = 110
    private static let popupMaxWidth: CGFloat = 135
    private var controls: [NSView] { [sizeSlider, namesCheckbox, fitPopup] }

    public init(preferencesStore: any DisplayPreferencesStore) {
        self.preferencesStore = preferencesStore
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignMetrics.radii["popover"]!
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Display and Appearance"))
        setAccessibilityIdentifier("grid.display.panel")
        addSubview(titleLabel)
        addSubview(closeButton)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = DesignColor.textPrimary.nsColor
        titleLabel.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.image = DesignSymbol.close.image()
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = DesignColor.textSecondary.nsColor
        closeButton.toolTip = String(localized: "Close Display Panel")
        closeButton.setAccessibilityLabel(String(localized: "Close Display Panel"))
        closeButton.setAccessibilityIdentifier("grid.display.close")
        closeButton.target = self
        closeButton.action = #selector(closeFromButton)
        sizeSlider.minValue = 140
        sizeSlider.maxValue = 280
        sizeSlider.numberOfTickMarks = 15
        sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.setAccessibilityLabel(String(localized: "Thumbnail Size"))
        sizeSlider.setAccessibilityIdentifier("grid.display.size")
        namesCheckbox.target = self
        namesCheckbox.action = #selector(namesChanged)
        namesCheckbox.setAccessibilityLabel(String(localized: "Show File Names"))
        namesCheckbox.setAccessibilityIdentifier("grid.display.names")
        fitPopup.addItems(withTitles: [String(localized: "Fill and Crop"), String(localized: "Fit Entire Image")])
        // A regular NSPopUpButton needs 137pt for "Fit Entire Image" at 12pt; the small control fits `max-width:135px`.
        fitPopup.controlSize = .small
        fitPopup.font = .systemFont(ofSize: 12)
        fitPopup.target = self
        fitPopup.action = #selector(fitChanged)
        fitPopup.setAccessibilityLabel(String(localized: "Thumbnails"))
        fitPopup.setAccessibilityIdentifier("grid.display.fit")
        for (row, (label, control)) in zip(rows, zip(rowLabels, controls)) {
            addSubview(row)
            row.addSubview(label)
            row.addSubview(control)
            label.font = .systemFont(ofSize: 12)
            label.textColor = DesignColor.textPrimary.nsColor
            label.lineBreakMode = .byTruncatingTail
        }
        closeButton.nextKeyView = sizeSlider
        sizeSlider.nextKeyView = namesCheckbox
        namesCheckbox.nextKeyView = fitPopup
        fitPopup.nextKeyView = closeButton
        reflect(preferencesStore.value)
        refreshAppearance()
    }
    public required init?(coder: NSCoder) { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
    /// `background: var(--color-panel)`, `box-shadow: var(--shadow-soft)` — the chrome groups' soft shadow.
    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = DesignColor.divider.nsColor.cgColor
            layer?.shadowColor = dark ? NSColor.black.cgColor : DesignColor.textPrimary.nsColor.cgColor
            layer?.shadowOpacity = dark ? 0.45 : 0.08
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: -8)
        }
    }

    public func reflect(_ preferences: DisplayPreferences) {
        sizeSlider.doubleValue = preferences.thumbnailSize
        namesCheckbox.state = preferences.showFileNames ? .on : .off
        fitPopup.selectItem(at: preferences.thumbnailFit == .fit ? 1 : 0)
    }
    private func write(_ change: (inout DisplayPreferences) -> Void) {
        var value = preferencesStore.value
        change(&value)
        preferencesStore.value = value
        reflect(preferencesStore.value)
    }
    @objc private func sizeChanged() {
        let size = DisplayPreferences.normalizedThumbnailSize(sizeSlider.doubleValue)
        write { $0.thumbnailSize = size }
    }
    @objc private func namesChanged() {
        let names = namesCheckbox.state == .on
        write { $0.showFileNames = names }
    }
    @objc private func fitChanged() {
        let fit: ThumbnailFit = fitPopup.indexOfSelectedItem == 1 ? .fit : .fill
        write { $0.thumbnailFit = fit }
    }
    @objc private func closeFromButton() { onClose?() }
    public override func cancelOperation(_ sender: Any?) { onClose?() }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    private func rowHeight(_ index: Int) -> CGFloat {
        let content = max(ceil(rowLabels[index].intrinsicContentSize.height), ceil(controlSize(index).height))
        return max(Self.rowMinHeight, content + 2 * Self.rowPadding.vertical)
    }
    private func controlSize(_ index: Int) -> NSSize {
        let intrinsic = controls[index].intrinsicContentSize
        return NSSize(width: max(0, intrinsic.width), height: max(0, intrinsic.height))
    }
    /// The panel's height: padding, the 28pt header, its 9pt gap and the three rows.
    public func fittingHeight() -> CGFloat {
        2 * Self.padding + 28 + Self.headerGap + rows.indices.reduce(0) { $0 + rowHeight($1) }
    }
    public override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 2 * Self.padding)
        var y = Self.padding
        for index in rows.indices.reversed() {
            let height = rowHeight(index)
            rows[index].frame = NSRect(x: Self.padding, y: y, width: inner, height: height)
            layoutRow(index, width: inner, height: height)
            y += height
        }
        let headerY = y + Self.headerGap
        closeButton.frame = NSRect(x: bounds.width - Self.padding - 30, y: headerY, width: 30, height: 28)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let titleWidth = min(ceil(titleLabel.cell!.cellSize.width), max(0, closeButton.frame.minX - Self.padding))
        titleLabel.frame = NSRect(x: Self.padding, y: headerY + ((28 - titleHeight) / 2).rounded(),
                                  width: titleWidth, height: titleHeight)
    }
    /// `.setting-row`: label at the leading padding, control at the trailing one; the label keeps its text and the
    /// slider and popup give up width first (popup title truncates at the narrowest shells).
    private func layoutRow(_ index: Int, width: CGFloat, height: CGFloat) {
        let label = rowLabels[index], control = controls[index]
        let inset = Self.rowPadding.horizontal
        let natural = controlSize(index)
        let fixedControl: CGFloat = control === namesCheckbox ? natural.width : 0
        let labelWidth = min(ceil(label.cell!.cellSize.width), max(0, width - 2 * inset - Self.rowGap - fixedControl))
        let room = max(0, width - 2 * inset - Self.rowGap - labelWidth)
        let controlWidth: CGFloat = switch index {
        case 0: min(Self.sliderWidth, room)
        case 2: min(Self.popupMaxWidth, ceil(natural.width), room)
        default: natural.width
        }
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: inset, y: ((height - labelHeight) / 2).rounded(), width: labelWidth, height: labelHeight)
        let controlHeight = natural.height
        control.frame = NSRect(x: width - inset - controlWidth, y: ((height - controlHeight) / 2).rounded(),
                               width: controlWidth, height: controlHeight)
    }
}
