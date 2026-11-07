import AppKit
import MadoApplication
import MadoCore

/// Layer-drawn page-22 control; keyboard focus follows the sidebar's controls.
@MainActor public class EmptyFolderControl: NSButton {
    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() {
        let radius = layer?.cornerRadius ?? 0
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    func setUp() { title = ""; isBordered = false; wantsLayer = true; focusRingType = .exterior }
}

@MainActor public final class EmptyFolderButton: EmptyFolderControl {
    public enum Style: Sendable { case primary, text, secondary }
    public private(set) var style: Style = .primary
    public private(set) var padding = NSEdgeInsets()
    public private(set) var titleColor: NSColor?
    public let titleFont = NSFont.systemFont(ofSize: 13)
    public var titleWidth: CGFloat { ceil(attributedTitle.size().width) }
    private var borderWidth: CGFloat { style == .secondary ? 1 : 0 }
    // Pinned 13pt button text has a 19pt normal line box.
    var actionSize: NSSize {
        NSSize(width: titleWidth + padding.left + padding.right + 2 * borderWidth,
               height: 19 + padding.top + padding.bottom + 2 * borderWidth)
    }
    func configure(_ style: Style, title: String) {
        setUp()
        self.style = style
        // empty-folder.html: .mock-primary 8/16, .mock-actions .text-button 8/4, .secondary-button 7/14.
        let (vertical, horizontal): (CGFloat, CGFloat) = switch style {
        case .primary: (8, 16)
        case .text: (8, 4)
        case .secondary: (7, 14)
        }
        padding = NSEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        let color = (style == .primary ? DesignColor.onPrimary : style == .text ? .selectionText : .textPrimary).nsColor
        titleColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: color])
        layer?.cornerRadius = style == .text ? 0 : 6
        layer?.borderWidth = borderWidth
    }
    func applyColors() {
        layer?.backgroundColor = style == .primary ? DesignColor.primaryFill.nsColor.cgColor
            : style == .secondary ? DesignColor.canvasBackground.nsColor.cgColor : nil
        layer?.borderColor = DesignColor.divider.nsColor.cgColor
    }
}

@MainActor public final class EmptyFolderTile: EmptyFolderControl {
    public let icon = NSImageView()
    public let nameLabel = NSTextField(labelWithString: "")
    public let metaLabel = NSTextField(labelWithString: String(localized: "Subfolder"))
    public let url: URL
    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        setUp()
        layer?.cornerRadius = 10; layer?.borderWidth = 1
        icon.image = NSImage(systemSymbolName: DesignSymbol.folder.name, accessibilityDescription: nil)
        icon.contentTintColor = DesignColor.accent.nsColor
        nameLabel.stringValue = url.lastPathComponent
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = DesignColor.textPrimary.nsColor
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.maximumNumberOfLines = 1
        metaLabel.font = .systemFont(ofSize: 12); metaLabel.textColor = DesignColor.textSecondary.nsColor
        [icon, nameLabel, metaLabel].forEach { addSubview($0); $0.setAccessibilityElement(false) }
        setAccessibilityLabel(String(format: String(localized: "%@, Subfolder"), url.lastPathComponent))
    }
    required init?(coder: NSCoder) { nil }
    /// .subfolder-tile: padding 14/12, gap 8, 16pt icon.
    // Pinned normal browser line boxes: name 19pt, metadata 17pt.
    static var height: CGFloat { 60 + 19 + 17 + 2 }
    public override func layout() {
        super.layout()
        let width = max(0, bounds.width - 26), nameHeight: CGFloat = 19
        icon.frame = NSRect(x: 13, y: bounds.height - 31, width: 16, height: 16)
        nameLabel.frame = NSRect(x: 13, y: icon.frame.minY - 8 - nameHeight, width: width, height: nameHeight)
        metaLabel.frame = NSRect(x: 13, y: 15, width: width, height: 17)
    }
}

@MainActor public final class EmptyFolderRecentButton: EmptyFolderControl {
    public let icon = NSImageView()
    public let nameLabel = NSTextField(labelWithString: "")
    public let whenLabel = NSTextField(labelWithString: "")
    public let separator = NSView()
    let folder: RecentFolder
    init(_ row: EmptyFolderRecentRow, first: Bool) {
        folder = row.folder
        super.init(frame: .zero)
        setUp()
        icon.image = NSImage(systemSymbolName: DesignSymbol.folder.name, accessibilityDescription: nil)
        icon.contentTintColor = DesignColor.textSecondary.nsColor
        nameLabel.stringValue = row.folder.displayName
        nameLabel.font = .systemFont(ofSize: 13); nameLabel.textColor = DesignColor.textPrimary.nsColor
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.maximumNumberOfLines = 1
        whenLabel.stringValue = row.relativeTime
        whenLabel.font = .systemFont(ofSize: 12); whenLabel.textColor = DesignColor.textSecondary.nsColor
        separator.wantsLayer = true; separator.isHidden = first
        [icon, nameLabel, whenLabel, separator].forEach { addSubview($0); $0.setAccessibilityElement(false) }
        setAccessibilityLabel(String(format: String(localized: "%1$@, %2$@", comment: "Recent folder row: name, opened time"),
                                     row.folder.displayName, row.relativeTime))
    }
    required init?(coder: NSCoder) { nil }
    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds) }
        return accepted
    }
    /// .recent-folder: padding 9/12, gap 10; .recent-folder+.recent-folder border-top 1.
    var height: CGFloat { 18 + 19 + (separator.isHidden ? 0 : 1) }
    public override func layout() {
        super.layout()
        let nameHeight: CGFloat = 19, whenHeight: CGFloat = 17
        let whenWidth = ceil(whenLabel.intrinsicContentSize.width)
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        icon.frame = NSRect(x: 12, y: 9 + (nameHeight - 16) / 2, width: 16, height: 16)
        whenLabel.frame = NSRect(x: bounds.width - 12 - whenWidth, y: 9 + (nameHeight - whenHeight) / 2,
                                 width: whenWidth, height: whenHeight)
        nameLabel.frame = NSRect(x: 38, y: 9, width: max(0, whenLabel.frame.minX - 48), height: nameHeight)
    }
}

/// What page 22 shows: subfolder tiles (with 「包含子文件夹浏览」 when available), else recents.
public struct EmptyFolderPage: Equatable, Sendable {
    public let subfolders: [URL]
    public let recents: [EmptyFolderRecentRow]
    public let includeSubfoldersAvailable: Bool
    public init(subfolders: [URL], recents: [EmptyFolderRecentRow], includeSubfoldersAvailable: Bool) {
        self.subfolders = subfolders; self.recents = recents; self.includeSubfoldersAvailable = includeSubfoldersAvailable
    }
}

@MainActor private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Page 22 (22-BD): the grid shell's content after a complete scan found no images (ADR-014).
@MainActor public final class EmptyFolderStateView: NSView {
    public let scrollView = NSScrollView()
    public let icon = NSImageView()
    public let heading = NSTextField(wrappingLabelWithString: "")
    public let detail = NSTextField(wrappingLabelWithString: "")
    public let primaryButton = EmptyFolderButton()
    public let chooseButton = EmptyFolderButton()
    public let recentsGroup = NSView()
    public let recentsHeadingBox = NSView()
    public let recentsHeading = NSTextField(labelWithString: String(localized: "Recently Opened"))
    public let recentsHeadingRule = NSView()
    public let dropOutline = NSView()
    public let dropBorder = CAShapeLayer()
    public private(set) var tiles: [EmptyFolderTile] = []
    public private(set) var recentRows: [EmptyFolderRecentButton] = []
    public private(set) var isDragOver = false
    public var onSelectSubfolder: ((URL) -> Void)?
    public var onOpenRecent: ((RecentFolder) -> Void)?
    public var onIncludeSubfolders: (() -> Void)?
    public var onChooseFolder: (() -> Void)?
    public var onDropFolders: (([URL]) -> Void)?
    // Stack padding belongs inside the full-frame scroll/drop destination.
    // Grid supplies CSS grid-scroll padding; the viewer uses zero insets.
    var contentInsets = NSEdgeInsets() { didSet { needsLayout = true } }
    private let document = FlippedView()
    private let recentDocument = NSView()
    private var resetRecentScroll = true
    private var displayedRequest: EmptyFolderPage?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true; scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        addSubview(scrollView)
        addSubview(dropOutline)
        icon.image = NSImage(systemSymbolName: DesignSymbol.folder.name, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        icon.contentTintColor = DesignColor.textSecondary.nsColor
        icon.setAccessibilityElement(false)
        heading.font = .systemFont(ofSize: 16, weight: .medium)
        heading.textColor = DesignColor.textPrimary.nsColor
        heading.alignment = .center; heading.isSelectable = false; detail.isSelectable = false
        heading.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        primaryButton.configure(.primary, title: String(localized: "Browse Including Subfolders"))
        primaryButton.target = self; primaryButton.action = #selector(includeSubfolders)
        chooseButton.target = self; chooseButton.action = #selector(chooseFolder)
        recentsGroup.wantsLayer = true
        recentsGroup.layer?.cornerRadius = 10; recentsGroup.layer?.borderWidth = 1; recentsGroup.layer?.masksToBounds = true
        recentsGroup.setAccessibilityElement(true); recentsGroup.setAccessibilityRole(.group)
        recentsGroup.setAccessibilityLabel(recentsHeading.stringValue)
        recentsHeadingBox.wantsLayer = true; recentsHeadingRule.wantsLayer = true
        recentsHeading.font = .systemFont(ofSize: 12); recentsHeading.textColor = DesignColor.textSecondary.nsColor
        recentsHeadingBox.addSubview(recentsHeading); recentsHeadingBox.addSubview(recentsHeadingRule)
        recentsGroup.addSubview(recentsHeadingBox)
        [icon, heading, detail, recentsGroup, primaryButton, chooseButton].forEach { document.addSubview($0) }
        // .drop-outline: inset 18, 1.5px dashed, radius 14; shown only while a folder is dragged over.
        dropOutline.wantsLayer = true; dropOutline.isHidden = true
        dropOutline.layer?.cornerRadius = 14
        dropBorder.lineWidth = 1.5; dropBorder.lineDashPattern = [6, 4]; dropBorder.fillColor = nil
        dropOutline.layer?.addSublayer(dropBorder)
        dropOutline.setAccessibilityElement(false)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Content area: drop a folder to open it"))
        applyColors()
    }
    public required init?(coder: NSCoder) { nil }

    public var keyViews: [NSView] {
        (tiles.isEmpty ? recentRows : tiles) + (primaryButton.isHidden ? [] : [primaryButton]) + [chooseButton]
    }
    /// Subfolder tiles (with 「包含子文件夹浏览」 when `includeSubfoldersAvailable`), else the recents list.
    public func display(subfolders: [URL], recents: [EmptyFolderRecentRow], includeSubfoldersAvailable: Bool) {
        // A repeated request (watched refresh, recents reload) keeps the controls so keyboard focus stays put.
        let request = EmptyFolderPage(subfolders: subfolders, recents: recents,
                                      includeSubfoldersAvailable: includeSubfoldersAvailable)
        guard request != displayedRequest else { return }
        displayedRequest = request
        // A live change rebuilds the controls; focus returns to the same folder's control, else to the same position.
        let focusedIndex = keyViews.firstIndex { $0 === window?.firstResponder }
        let focusedIdentity = focusedIndex.map { Self.identity(of: keyViews[$0]) }
        tiles.forEach { $0.removeFromSuperview() }; recentRows.forEach { $0.removeFromSuperview() }
        tiles = subfolders.map { url in
            let tile = EmptyFolderTile(url: url)
            tile.target = self; tile.action = #selector(selectTile(_:))
            document.addSubview(tile)
            return tile
        }
        resetRecentScroll = true
        recentRows = subfolders.isEmpty ? recents.enumerated().map { index, row in
            let button = EmptyFolderRecentButton(row, first: index == 0)
            button.target = self; button.action = #selector(selectRecent(_:))
            recentDocument.addSubview(button)
            return button
        } : []
        recentsGroup.isHidden = recentRows.isEmpty
        primaryButton.isHidden = tiles.isEmpty || !includeSubfoldersAvailable
        heading.stringValue = tiles.isEmpty ? String(localized: "This folder has no images to browse yet")
            : String(localized: "This level has no images, but has \(tiles.count) subfolders")
        setDetailText(tiles.isEmpty ? String(localized: "Choose another folder to continue, or drop a folder here.")
            : String(localized: "Open a subfolder, show the images in subfolders too, or drop another folder here."))
        chooseButton.configure(tiles.isEmpty ? .secondary : .text, title: String(localized: "Choose Another Folder…"))
        applyColors()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let focusedIndex, let window {
            let views = keyViews
            window.makeFirstResponder(views.first { Self.identity(of: $0) == focusedIdentity }
                ?? views[min(focusedIndex, views.count - 1)])
        }
    }
    private static func identity(of control: NSView) -> AnyHashable {
        switch control {
        case let tile as EmptyFolderTile: tile.url
        case let row as EmptyFolderRecentButton: [row.folder.rootID.rawValue.uuidString, row.folder.url.path]
        default: ObjectIdentifier(control)
        }
    }
    public func setDetailText(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 22.1; paragraph.maximumLineHeight = 22.1 // line-height 1.7 × 13
        detail.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: DesignColor.textSecondary.nsColor, .paragraphStyle: paragraph,
        ])
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for tile in tiles {
                tile.layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
                tile.layer?.borderColor = DesignColor.divider.nsColor.cgColor
            }
            for row in recentRows {
                row.layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
                row.separator.layer?.backgroundColor = DesignColor.dividerSubtle.nsColor.cgColor
            }
            recentsGroup.layer?.borderColor = DesignColor.divider.nsColor.cgColor
            recentsHeadingBox.layer?.backgroundColor = DesignColor.sidebarBackground.nsColor.cgColor
            recentsHeadingRule.layer?.backgroundColor = DesignColor.divider.nsColor.cgColor
            primaryButton.applyColors(); chooseButton.applyColors()
            dropOutline.layer?.backgroundColor = DesignColor.selectionFill.nsColor.cgColor
            dropBorder.strokeColor = DesignColor.accent.nsColor.cgColor
        }
    }

    /// Pinned normal h2 line box is 23pt; p is explicitly 13 × 1.7 = 22.1pt.
    /// Measure wrapping with that line box rather than rounding AppKit's ink height.
    private func measuredHeight(_ field: NSTextField, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        let text = NSMutableAttributedString(attributedString: field.attributedStringValue)
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return ceil(max(lineHeight, text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
    }
    /// empty-folder.html: .empty-state padding 24 (.recovery-state padding-bottom 48), centred column;
    /// h2 margin-top 18, p margin-top 9 and max-width 460, tiles/recents margin-top 22, actions margin-top 18 gap 16.
    public override func layout() {
        super.layout()
        let showingRecents = tiles.isEmpty
        dropOutline.frame = bounds.insetBy(dx: 18, dy: 18)
        dropBorder.frame = dropOutline.bounds
        dropBorder.path = CGPath(roundedRect: dropOutline.bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 13.25,
                                 cornerHeight: 13.25, transform: nil)
        let viewport = bounds.size
        // The flex item's automatic minimum includes the 380pt recent list and
        // .empty-state's two 24pt sides. Preserve it when the main area is narrow.
        let width = recentsGroup.isHidden ? viewport.width : max(viewport.width, 380 + 48)
        let textWidth = max(0, min(460, width - 48))
        let headingHeight = measuredHeight(heading, width: textWidth, lineHeight: 23)
        let detailHeight = measuredHeight(detail, width: textWidth, lineHeight: 22.1)
        let tileRows = (tiles.count + 2) / 3, tileHeight = EmptyFolderTile.height
        let naturalGroup: CGFloat = recentRows.isEmpty ? 0 : 36 + recentRows.map(\.height).reduce(0, +)
        // #518 approved pin: normal24/48/18/9/22/18; compact8/16/10/6/12/12.
        // Spend optional spacing proportionally before bounding the row viewport.
        var spaces: [CGFloat] = [24, 48, 18, 9, recentRows.isEmpty ? 0 : 22, 18]
        let available = max(0, viewport.height - contentInsets.top - contentInsets.bottom)
        var groupHeight = naturalGroup
        var scrollRows = false
        if showingRecents {
            let compact: [CGFloat] = [8, 16, 10, 6, recentRows.isEmpty ? 0 : 12, 12]
            let fixed = 32 + headingHeight + detailHeight + chooseButton.actionSize.height
            let minimumGroup = recentRows.first.map { 36 + $0.height } ?? 0
            scrollRows = available >= fixed + compact.reduce(0, +) + minimumGroup
            if scrollRows {
                let savings = zip(spaces, compact).reduce(0) { $0 + $1.0 - $1.1 }
                let excess = max(0, fixed + naturalGroup + spaces.reduce(0, +) - available)
                let reduction = min(1, excess / savings)
                spaces = zip(spaces, compact).map { $0 - ($0 - $1) * reduction }
                groupHeight = min(naturalGroup, max(0, available - fixed - spaces.reduce(0, +)))
            } else {
                // Below one complete row, scroll the whole stack instead of
                // collapsing its heading/rows or stranding the choose action.
                spaces = compact
            }
        }
        configureScrollDocument(scrollRows: scrollRows)
        if !scrollRows { scrollView.frame = bounds }
        let middle: CGFloat = !tiles.isEmpty ? 22 + CGFloat(tileRows) * (tileHeight + 14) - 14
            : recentsGroup.isHidden ? 0 : spaces[4] + groupHeight
        let actions = [primaryButton, chooseButton].filter { !$0.isHidden }
        let actionHeight = actions.reduce(0) { max($0, $1.actionSize.height) }
        let content = 32 + spaces[2] + headingHeight + spaces[3] + detailHeight + middle + spaces[5] + actionHeight
        let verticalInsets = contentInsets.top + contentInsets.bottom
        document.frame = NSRect(x: 0, y: 0, width: width,
            height: scrollRows ? viewport.height : max(viewport.height,
                content + spaces[0] + spaces[1] + verticalInsets))
        var top = contentInsets.top + spaces[0]
            + max(0, (available - spaces[0] - spaces[1] - content) / 2)
        icon.frame = NSRect(x: width / 2 - 16, y: top, width: 32, height: 32)
        top += 32 + spaces[2]
        heading.frame = NSRect(x: (width - textWidth) / 2, y: top, width: textWidth, height: headingHeight)
        top += headingHeight + spaces[3]
        detail.frame = NSRect(x: (width - textWidth) / 2, y: top, width: textWidth, height: detailHeight)
        top += detailHeight + (showingRecents ? spaces[4] : 22)
        let gridX = (width - 478) / 2 // repeat(3, 150px), gap 14
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: gridX + CGFloat(index % 3) * 164, y: top + CGFloat(index / 3) * (tileHeight + 14),
                                width: 150, height: tileHeight)
        }
        recentsGroup.frame = NSRect(x: (width - 380) / 2, y: top, width: 380, height: groupHeight)
        if showingRecents { layoutRecents(height: groupHeight, scrollRows: scrollRows) }
        top = detail.frame.maxY + middle + spaces[5]
        let actionsWidth = actions.map(\.actionSize.width).reduce(0, +) + CGFloat(actions.count - 1) * 16
        var x = (width - actionsWidth) / 2
        for button in actions {
            let size = button.actionSize
            button.frame = NSRect(x: x, y: top + (actionHeight - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 16
        }
    }
    /// Reuse one system scroller. Bound recent rows only while a complete row
    /// fits; shorter pages and subfolders use the whole-page document.
    private func configureScrollDocument(scrollRows: Bool) {
        let target: NSView = scrollRows ? recentDocument : document
        guard scrollView.documentView !== target else { return }
        scrollView.documentView = nil
        scrollView.removeFromSuperview()
        if scrollRows {
            addSubview(document, positioned: .below, relativeTo: dropOutline)
            recentsGroup.addSubview(scrollView)
            resetRecentScroll = true
        } else {
            document.removeFromSuperview()
            addSubview(scrollView, positioned: .below, relativeTo: dropOutline)
        }
        scrollView.documentView = target
    }

    /// .recent-folders border1, header34, then a bounded row-only viewport.
    private func layoutRecents(height total: CGFloat, scrollRows: Bool) {
        let boxHeight: CGFloat = 34
        let atTop = recentDocument.bounds.maxY - scrollView.contentView.bounds.maxY <= 1
        recentsHeadingBox.frame = NSRect(x: 1, y: total - 1 - boxHeight, width: 378, height: boxHeight)
        recentsHeadingRule.frame = NSRect(x: 0, y: 0, width: 378, height: 1)
        recentsHeading.frame = NSRect(x: 12, y: 9, width: 354, height: 17)
        let rowHeight = recentRows.map(\.height).reduce(0, +)
        if scrollRows {
            scrollView.frame = NSRect(x: 1, y: 1, width: 378, height: max(0, total - 2 - boxHeight))
        } else if recentDocument.superview !== recentsGroup {
            recentsGroup.addSubview(recentDocument)
        }
        recentDocument.frame = NSRect(x: scrollRows ? 0 : 1, y: scrollRows ? 0 : 1, width: 378, height: rowHeight)
        var y = rowHeight
        for row in recentRows {
            y -= row.height
            row.frame = NSRect(x: 0, y: y, width: 378, height: row.height)
        }
        if scrollRows && (resetRecentScroll || atTop) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rowHeight - scrollView.contentSize.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        resetRecentScroll = false
        if let focused = window?.firstResponder as? EmptyFolderRecentButton, recentRows.contains(focused) {
            focused.scrollToVisible(focused.bounds)
        }
    }

    @objc private func selectTile(_ sender: EmptyFolderTile) { onSelectSubfolder?(sender.url) }
    @objc private func selectRecent(_ sender: EmptyFolderRecentButton) { onOpenRecent?(sender.folder) }
    @objc private func includeSubfolders() { onIncludeSubfolders?() }
    @objc private func chooseFolder() { onChooseFolder?() }

    private func droppedURLs(_ sender: any NSDraggingInfo) -> [URL] {
        guard !isHiddenOrHasHiddenAncestor, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        // The drop target says "drop a folder": files are refused.
        return urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
    private func setDragOver(_ value: Bool) { isDragOver = value; dropOutline.isHidden = !value }
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        setDragOver(!droppedURLs(sender).isEmpty)
        return isDragOver ? .copy : []
    }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { setDragOver(false) }
    public override func draggingEnded(_ sender: any NSDraggingInfo) { setDragOver(false) }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        setDragOver(false)
        guard !urls.isEmpty else { return false }
        onDropFolders?(urls)
        return true
    }
}
