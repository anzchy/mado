import AppKit
import MadoApplication

public struct GridSidebarFolder: Sendable, Equatable {
    public let url: URL
    public let count: Int?
    public let accessLossCause: AccessLossCause?
    public init(url: URL, count: Int? = nil, accessLossCause: AccessLossCause? = nil) {
        self.url = url; self.count = count; self.accessLossCause = accessLossCause
    }
}

@MainActor public final class GridSidebarFolderButton: NSButton {
    public let folderURL: URL
    public let nameLabel = NSTextField(labelWithString: "")
    public let countLabel = NSTextField(labelWithString: "")
    public let glyph = NSImageView()
    public let warningGlyph = NSImageView()
    public let disclosureGlyph = NSImageView()
    public let depth: Int
    public let current: Bool
    public let accessLossCause: AccessLossCause?
    public var compact = false {
        didSet {
            nameLabel.font = .systemFont(ofSize: compact ? 12 : 13)
            needsLayout = true
        }
    }
    public init(folder: GridSidebarFolder, depth: Int, current: Bool) {
        self.folderURL = folder.url; self.depth = depth; self.current = current
        self.accessLossCause = folder.accessLossCause
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 6
        for view in [glyph, nameLabel, countLabel, warningGlyph, disclosureGlyph] { addSubview(view) }
        nameLabel.stringValue = folder.url.lastPathComponent
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        glyph.image = current ? Self.openFolderImage() : NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.setAccessibilityElement(false)
        warningGlyph.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        warningGlyph.imageScaling = .scaleProportionallyDown
        warningGlyph.isHidden = folder.accessLossCause == nil
        warningGlyph.setAccessibilityElement(true)
        warningGlyph.setAccessibilityLabel(String(localized: "Unavailable"))
        disclosureGlyph.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        disclosureGlyph.imageScaling = .scaleProportionallyDown
        disclosureGlyph.isHidden = folder.accessLossCause == nil
        disclosureGlyph.setAccessibilityElement(false)
        countLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        setCount(folder.count)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("grid.sidebar.folder.\(folder.url.lastPathComponent)")
        refreshAccessibility()
        refreshAppearance()
    }
    public required init?(coder: NSCoder) { nil }
    private static func openFolderImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { _ in
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 2, y: 4))
            back.line(to: NSPoint(x: 2, y: 12))
            back.line(to: NSPoint(x: 6, y: 12))
            back.line(to: NSPoint(x: 7.5, y: 10.5))
            back.line(to: NSPoint(x: 15, y: 10.5))
            back.line(to: NSPoint(x: 15, y: 4))
            back.lineWidth = 1.5
            back.lineJoinStyle = .round
            back.stroke()
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: 2, y: 4))
            flap.line(to: NSPoint(x: 4, y: 9))
            flap.line(to: NSPoint(x: 16, y: 9))
            flap.line(to: NSPoint(x: 14, y: 3))
            flap.close()
            flap.lineWidth = 1.5
            flap.lineJoinStyle = .round
            flap.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
    public override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    public func setCount(_ count: Int?) {
        countLabel.stringValue = count.map(String.init) ?? ""
        countLabel.isHidden = accessLossCause != nil || count == nil
        let name = folderURL.lastPathComponent
        if accessLossCause == nil, let count {
            let images = String(format: String(localized: "%lld images"), Int64(count))
            setAccessibilityLabel("\(name), \(images)")
        } else { setAccessibilityLabel(name) }
        needsLayout = true
    }
    private func refreshAccessibility() {
        guard let accessLossCause else {
            setAccessibilityValue(current ? String(localized: "Selected") : nil)
            setAccessibilityHelp(nil)
            return
        }
        let cause: String
        switch accessLossCause {
        case .accessExpired: cause = String(localized: "Access Has Expired")
        case .diskNotConnected: cause = String(localized: "External Disk Is Not Connected")
        case .notFound: cause = String(localized: "Not Found")
        case .unknown: cause = String(localized: "Unable to Access This Folder")
        }
        let value = "\(String(localized: "Unavailable")), \(cause)"
        setAccessibilityValue(value)
        setAccessibilityHelp(value)
    }
    /// A folder whose read did not finish: `—` and no count.
    public func setUnreadCount() {
        countLabel.stringValue = "—"
        countLabel.isHidden = accessLossCause != nil
        let name = folderURL.lastPathComponent
        if accessLossCause == nil {
            setAccessibilityLabel("\(name), \(String(localized: "Read incomplete"))")
        } else {
            setAccessibilityLabel(name)
        }
        needsLayout = true
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
    private func refreshAppearance() {
        func resolved(_ designColor: DesignColor) -> NSColor {
            let theme: DesignTheme = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            let components = designColor.components(theme)
            return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
        }
        layer?.backgroundColor = accessLossCause != nil ? resolved(.hoverBackground).cgColor
            : current ? resolved(.selectionFill).cgColor : NSColor.clear.cgColor
        nameLabel.textColor = accessLossCause != nil ? resolved(.textSecondary)
            : current ? resolved(.selectionText) : resolved(.textPrimary)
        countLabel.textColor = resolved(.textSecondary)
        glyph.contentTintColor = accessLossCause != nil ? resolved(.textSecondary)
            : current ? resolved(.selectionText) : resolved(.textSecondary)
        warningGlyph.contentTintColor = current ? resolved(.waitingIndicator) : resolved(.textSecondary)
        disclosureGlyph.contentTintColor = resolved(.textSecondary)
    }
    public override func layout() {
        super.layout()
        let padding: CGFloat = compact ? (depth > 0 ? 9 : 7) : 10
        glyph.frame = NSRect(x: padding, y: depth > 0 && !current ? 8 : 7,
            width: depth > 0 && !current ? 16 : 17, height: depth > 0 && !current ? 16 : 17)
        let countWidth: CGFloat = countLabel.isHidden ? 0 : max(13, countLabel.intrinsicContentSize.width)
        countLabel.frame = NSRect(x: bounds.width - padding - countWidth, y: 7, width: countWidth, height: 18)
        disclosureGlyph.frame = NSRect(x: bounds.width - padding - 12, y: 10, width: 12, height: 12)
        warningGlyph.frame = NSRect(x: disclosureGlyph.frame.minX - 11 - 14, y: 9, width: 14, height: 14)
        let labelX = glyph.frame.maxX + (compact ? 6 : 9)
        let trailing = accessLossCause == nil ? countLabel.frame.minX - (countLabel.isHidden ? 0 : 8)
            : warningGlyph.frame.minX - 9
        nameLabel.frame = NSRect(x: labelX, y: 6, width: max(0, trailing - labelX), height: 20)
    }
}

/// These coming-soon controls stay disabled while retaining the pinned sidebar ink.
/// Native disabled NSButton drawing attenuates even an attributed title or template image.
@MainActor private final class GridSidebarAddFolderButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink = DesignColor.textSecondary.nsColor
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: ink,
            ])
            let hasLabel = !title.isEmpty
            let glyphSize: CGFloat = hasLabel ? 15 : 14
            let textSize = text.size()
            let groupWidth = glyphSize + (hasLabel ? 7 + textSize.width : 0)
            let glyph = NSRect(x: bounds.midX - groupWidth / 2, y: bounds.midY - glyphSize / 2,
                width: glyphSize, height: glyphSize)
            // grid-light/folder-loading: SVG viewBox 24, M12 5v14M5 12h14.
            ink.setStroke()
            let plus = NSBezierPath()
            plus.lineWidth = glyphSize * 1.75 / 24
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: glyph.midX, y: glyph.minY + glyphSize * 5 / 24))
            plus.line(to: NSPoint(x: glyph.midX, y: glyph.minY + glyphSize * 19 / 24))
            plus.move(to: NSPoint(x: glyph.minX + glyphSize * 5 / 24, y: glyph.midY))
            plus.line(to: NSPoint(x: glyph.minX + glyphSize * 19 / 24, y: glyph.midY))
            plus.stroke()
            if hasLabel {
                text.draw(at: NSPoint(x: glyph.maxX + 7, y: bounds.midY - textSize.height / 2))
            }
        }
    }
}

@MainActor public final class GridSidebarTreeView: NSView {
    public let heading = NSTextField(labelWithString: "")
    public let guide = NSView()
    public var viewportWidth: CGFloat = 1280 { didSet { if oldValue != viewportWidth { needsLayout = true } } }
    public private(set) var rows: [GridSidebarFolderButton] = []
    public var onSelectFolder: ((URL) -> Void)?
    private let scroll = NSScrollView()
    private let document = NSView()
    private let addFolderButton = GridSidebarAddFolderButton()
    private let addFolderPlusButton = GridSidebarAddFolderButton()
    private let addFolderBorder = CAShapeLayer()
    public private(set) var parent: GridSidebarFolder?
    private var currentFolder: GridSidebarFolder?
    public var currentFolderURL: URL? { currentFolder?.url }
    /// Page 24 masks the main-read owner even when another sidebar row is selected.
    public var readingFolderURL: URL? {
        didSet {
            guard oldValue != readingFolderURL else { return }
            // show() appends parent, current, then children in this same order.
            for (folder, row) in zip([parent, currentFolder].compactMap { $0 } + children, rows) {
                applyCount(folder.count, to: row)
            }
        }
    }
    public var currentAccessLossCause: AccessLossCause? { currentFolder?.accessLossCause }
    public private(set) var children: [GridSidebarFolder] = []
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        addSubview(scroll)
        document.addSubview(heading)
        document.addSubview(guide)
        heading.stringValue = String(localized: "Folders")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.attributedStringValue = NSAttributedString(string: heading.stringValue,
            attributes: [.font: heading.font!, .kern: 0.48])
        heading.textColor = DesignColor.textSecondary.nsColor
        guide.wantsLayer = true
        guide.layer?.backgroundColor = DesignColor.divider.nsColor.cgColor
        guide.isHidden = true
        addFolderPlusButton.title = ""
        addFolderPlusButton.isBordered = false
        addFolderPlusButton.isEnabled = false
        addFolderPlusButton.refusesFirstResponder = true
        addFolderPlusButton.setAccessibilityIdentifier("grid.sidebar.add-folder-plus")
        addFolderPlusButton.setAccessibilityElement(true)
        addFolderPlusButton.setAccessibilityLabel("\(String(localized: "Add Folder")) · \(String(localized: "Coming Soon"))")
        document.addSubview(addFolderPlusButton)
        addFolderButton.title = String(localized: "Add Folder")
        addFolderButton.font = .systemFont(ofSize: 12)
        addFolderButton.isBordered = false
        addFolderButton.isEnabled = false
        addFolderButton.refusesFirstResponder = true
        addFolderButton.setAccessibilityIdentifier("grid.sidebar.add-folder")
        addFolderButton.setAccessibilityLabel("\(addFolderButton.title) · \(String(localized: "Coming Soon"))")
        addFolderButton.wantsLayer = true
        addFolderButton.layer?.cornerRadius = DesignMetrics.radii["control"]!
        addFolderBorder.fillColor = NSColor.clear.cgColor
        addFolderBorder.strokeColor = DesignColor.divider.nsColor.cgColor
        addFolderBorder.lineWidth = 1
        addFolderBorder.lineDashPattern = [4, 3]
        addFolderButton.layer?.addSublayer(addFolderBorder)
        document.addSubview(addFolderButton)
    }
    public required init?(coder: NSCoder) { nil }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            heading.textColor = DesignColor.textSecondary.nsColor
            guide.layer?.backgroundColor = DesignColor.divider.nsColor.cgColor
            addFolderBorder.strokeColor = DesignColor.divider.nsColor.cgColor
            addFolderButton.needsDisplay = true
            addFolderPlusButton.needsDisplay = true
        }
    }
    public func show(current: GridSidebarFolder, parent: GridSidebarFolder?, children: [GridSidebarFolder]) {
        let visibleChildren = current.accessLossCause == nil ? children : []
        self.parent = parent; currentFolder = current; self.children = visibleChildren
        for row in rows { row.removeFromSuperview() }
        rows = []
        if let parent { append(parent, depth: 0, current: false) }
        let depth = parent == nil ? 0 : 1
        append(current, depth: depth, current: true)
        for child in visibleChildren { append(child, depth: depth + 1, current: false) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
    }
    public func clear() {
        parent = nil; currentFolder = nil; children = []
        for row in rows { row.removeFromSuperview() }
        rows = []
        guide.isHidden = true
        needsLayout = true
    }
    /// Legacy presentation option; the Reading State keeps unknown counts absent.
    public var showsZeroForUnknownCurrent = false {
        didSet {
            guard let currentFolder, let row = rows.first(where: { $0.current }) else { return }
            applyCount(currentFolder.count, to: row)
        }
    }
    /// 24F-A: the folder whose read failed shows `—`, never a partial count (#238).
    public var showsDashForCurrent = false {
        didSet { if let row = rows.first(where: { $0.current }) { applyCount(currentFolder?.count, to: row) } }
    }
    private func applyCount(_ count: Int?, to row: GridSidebarFolderButton) {
        if row.current && showsDashForCurrent { row.setUnreadCount() }
        else { row.setCount(shownCount(count, for: row.folderURL, current: row.current)) }
        row.needsLayout = true
    }
    private func shownCount(_ count: Int?, for folder: URL, current: Bool) -> Int? {
        if folder.standardizedFileURL.path == readingFolderURL?.standardizedFileURL.path { return nil }
        return count ?? (current && showsZeroForUnknownCurrent ? 0 : nil)
    }
    private func append(_ folder: GridSidebarFolder, depth: Int, current: Bool) {
        let row = GridSidebarFolderButton(folder: GridSidebarFolder(url: folder.url,
            count: shownCount(folder.count, for: folder.url, current: current), accessLossCause: folder.accessLossCause),
            depth: depth, current: current)
        if depth > 0 && !current { row.countLabel.alphaValue = 0.8 }
        if current && showsDashForCurrent { row.setUnreadCount() }
        row.target = self
        row.action = #selector(selectFolder(_:))
        document.addSubview(row)
        rows.append(row)
    }
    @objc private func selectFolder(_ sender: GridSidebarFolderButton) {
        guard !sender.current else { return }
        onSelectFolder?(sender.folderURL)
    }
    public func updateCount(_ count: Int?, for url: URL) {
        if currentFolder?.url == url {
            currentFolder = GridSidebarFolder(url: url, count: count, accessLossCause: currentFolder?.accessLossCause)
        }
        if parent?.url == url { parent = GridSidebarFolder(url: url, count: count, accessLossCause: parent?.accessLossCause) }
        if let index = children.firstIndex(where: { $0.url == url }) {
            children[index] = GridSidebarFolder(url: url, count: count, accessLossCause: children[index].accessLossCause)
        }
        if let row = rows.first(where: { $0.folderURL == url }) { applyCount(count, to: row) }
    }
    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let rowHeight: CGFloat = 32
        let compact = viewportWidth <= 720
        let headerTop: CGFloat = compact ? 44 : 50 // sidebar padding + folder heading 28pt margin
        let headerHeight: CGFloat = 14
        let firstRowTop = headerTop + headerHeight + 8
        func gapBefore(_ index: Int) -> CGFloat {
            index > 0 && rows[index].depth > rows[index - 1].depth ? 3 : 0
        }
        let rowsHeight = rows.indices.reduce(CGFloat(0)) { $0 + rowHeight + gapBefore($1) }
        let documentHeight = max(bounds.height, firstRowTop + rowsHeight + 12 + 30 + 16)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: documentHeight)
        heading.frame = NSRect(x: compact ? 20 : 22, y: documentHeight - headerTop - headerHeight,
            width: max(0, bounds.width - 66), height: headerHeight)
        let sidebarPadding: CGFloat = viewportWidth <= 1050 ? 8 : 12
        // Sidebar border1 + padding + heading padding10 + tiny-button18 (SVG14 + padding2×2).
        addFolderPlusButton.frame = NSRect(x: max(0, bounds.width - 1 - sidebarPadding - 10 - 18),
            y: heading.frame.minY - 2, width: 18, height: 18)
        var rowY = documentHeight - firstRowTop
        for (index, row) in rows.enumerated() {
            row.compact = compact
            let x: CGFloat = 12 + CGFloat(row.depth) * (compact ? 8 : 19)
            rowY -= gapBefore(index) + rowHeight
            row.frame = NSRect(x: x, y: rowY, width: max(0, bounds.width - x - 12), height: rowHeight)
            row.layoutSubtreeIfNeeded()
        }
        addFolderButton.frame = NSRect(x: sidebarPadding + 4, y: rowY - 12 - 30,
            width: max(0, bounds.width - 2 * sidebarPadding - 1 - 8), height: 30)
        addFolderBorder.frame = addFolderButton.bounds
        addFolderBorder.path = NSBezierPath(roundedRect: addFolderButton.bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DesignMetrics.radii["control"]!, yRadius: DesignMetrics.radii["control"]!).cgPath
        if let firstChild = rows.firstIndex(where: { $0.depth > (parent == nil ? 0 : 1) }) {
            guide.isHidden = false
            let lastRowY = rows[rows.count - 1].frame.minY
            guide.frame = NSRect(x: rows[firstChild].frame.minX - (compact ? 3 : 6), y: lastRowY,
                width: 1, height: max(0, rows[firstChild].frame.maxY - lastRowY))
        } else { guide.isHidden = true }
    }
}
