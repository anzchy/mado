import AppKit

final class ShortcutTextField: NSTextField {
    private var text: NSAttributedString {
        NSAttributedString(string: stringValue, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor ?? NSColor.labelColor,
        ])
    }

    override var intrinsicContentSize: NSSize {
        let size = text.size()
        return NSSize(width: size.width, height: ceil(size.height))
    }

    func fittingSize(constrainedToWidth width: CGFloat) -> NSSize {
        let rect = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = text
        let size = text.size()
        let x: CGFloat
        let width: CGFloat
        switch alignment {
        case .center:
            x = bounds.minX + (bounds.width - size.width) / 2
            width = size.width
        default:
            x = bounds.minX
            width = bounds.width
        }
        let rect = NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            text.draw(in: rect)
        }
    }
}

@MainActor private func shortcutTextField(_ string: String) -> ShortcutTextField {
    ShortcutTextField(labelWithString: string)
}

final class ShortcutKeycapView: NSView {
    let label: NSTextField
    let bottomEdge = NSView()

    init(_ glyph: String) {
        label = shortcutTextField(glyph)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.textColor = DesignColor.textPrimary.nsColor
        label.lineBreakMode = .byClipping
        addSubview(label)
        bottomEdge.wantsLayer = true
        addSubview(bottomEdge)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    var preferredWidth: CGFloat { max(22, label.intrinsicContentSize.width + 14) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 7, y: 0, width: max(0, bounds.width - 14), height: bounds.height)
        bottomEdge.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = DesignColor.divider.nsColor.cgColor
            layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
            bottomEdge.layer?.backgroundColor = DesignColor.divider.nsColor.cgColor
        }
    }
}

final class ShortcutRowView: NSView {
    let nameLabel: NSTextField
    let keycapViews: [ShortcutKeycapView]
    let separator = NSView()

    init(row: ShortcutRow) {
        nameLabel = shortcutTextField(row.name)
        keycapViews = row.keycaps.map(ShortcutKeycapView.init)
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = DesignColor.textPrimary.nsColor
        nameLabel.lineBreakMode = .byClipping
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)
        for keycap in keycapViews { addSubview(keycap) }
        separator.wantsLayer = true
        addSubview(separator)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x = bounds.width
        for keycap in keycapViews.reversed() {
            let width = keycap.preferredWidth
            x -= width
            keycap.frame = NSRect(x: x, y: 6, width: width, height: 22)
            x -= 4
        }
        let keysMinX = keycapViews.first?.frame.minX ?? bounds.width
        let nameHeight = nameLabel.intrinsicContentSize.height + 2
        nameLabel.frame = NSRect(x: 0, y: (bounds.height - nameHeight) / 2,
            width: max(0, keysMinX - 8), height: nameHeight)
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = DesignColor.dividerSubtle.nsColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

final class ShortcutCardView: NSView {
    let titleLabel: ShortcutTextField
    let whenLabel: ShortcutTextField
    let rowViews: [ShortcutRowView]

    init(card: ShortcutCard) {
        titleLabel = shortcutTextField(card.title)
        whenLabel = shortcutTextField(card.when)
        rowViews = card.rows.map(ShortcutRowView.init)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = DesignColor.textPrimary.nsColor
        whenLabel.font = .systemFont(ofSize: 12)
        whenLabel.textColor = DesignColor.textSecondary.nsColor
        whenLabel.lineBreakMode = .byWordWrapping
        whenLabel.maximumNumberOfLines = 2
        whenLabel.cell?.wraps = true
        addSubview(titleLabel)
        addSubview(whenLabel)
        for (index, row) in rowViews.enumerated() {
            row.separator.isHidden = index == rowViews.count - 1
            addSubview(row)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    var requiredHeight: CGFloat { requiredHeight(forWidth: bounds.width) }

    private func headerHeight(forWidth width: CGFloat) -> CGFloat {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let whenWidth = max(0, width - 30 - titleWidth - 8)
        let whenHeight = whenLabel.fittingSize(constrainedToWidth: whenWidth).height
        return max(19, whenHeight + 2)
    }

    func requiredHeight(forWidth width: CGFloat) -> CGFloat {
        15 + headerHeight(forWidth: width) + 6 + CGFloat(rowViews.count) * 34 + 7
    }

    override func layout() {
        super.layout()
        let contentWidth = max(0, bounds.width - 30)
        let headerHeight = headerHeight(forWidth: bounds.width)
        titleLabel.frame = NSRect(x: 15, y: 15,
            width: titleLabel.intrinsicContentSize.width, height: headerHeight)
        let whenX = titleLabel.frame.maxX + 8
        let whenWidth = max(0, bounds.width - 15 - whenX)
        whenLabel.frame = NSRect(x: whenX, y: 17, width: whenWidth,
            height: whenLabel.fittingSize(constrainedToWidth: whenWidth).height)
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(x: 15, y: 15 + headerHeight + 6 + CGFloat(index) * 34,
                width: contentWidth, height: 34)
        }
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = DesignColor.divider.nsColor.cgColor
            layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
        }
    }
}

public final class ShortcutListView: NSView {
    let cardViews: [ShortcutCardView]

    public init(frame frameRect: NSRect, catalog: ShortcutCatalog) {
        cardViews = catalog.cards.map(ShortcutCardView.init)
        super.init(frame: frameRect)
        wantsLayer = true
        for card in cardViews { addSubview(card) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let gap: CGFloat = 14
        let width = floor((bounds.width - 36 - gap * 2) / 3)
        let height = cardViews.reduce(0) { max($0, $1.requiredHeight(forWidth: width)) }
        for (index, card) in cardViews.enumerated() {
            card.frame = NSRect(x: 18 + CGFloat(index) * (width + gap), y: 18, width: width, height: height)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
