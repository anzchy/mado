import AppKit
import MadoApplication
import MadoCore
import MadoMacUI

/// The Recognise Table result panel (#874, state 41 `result`): the original image beside the table, the row and
/// column count with the service name, and Copy Table. Resizable; nothing is copied or dismissed by itself.
///
/// Native exceptions to `table-flow.html`: the page's in-panel 「识别表格」 heading is the panel's title bar; the
/// page's floating 「✓ 表格已拷贝」 toast is a label beside Copy Table that stays until the panel closes (no timer,
/// story 43). Undo, 「第一行是表头」, the editable cell and 更多 are T6 (#875) and are not drawn yet.
@MainActor final class RecognisedTablePanel: NSPanel {
    /// State 41 draws the panel inset 70 × 100 in a 1280 × 800 page: 1080 × 660.
    static let defaultContentSize = NSSize(width: 1080, height: 660)
    static let minimumContentSize = NSSize(width: 640, height: 400)
    /// `.panel .body { grid-template-columns: 230px 1fr }`.
    static let sourceColumnWidth: CGFloat = 230

    let statusLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")
    let sourceCaption = NSTextField(labelWithString: "")
    let sourceImageView = NSImageView()
    let sourceColumn = NSView()
    let tableScroll = NSScrollView()
    let tableText = NSTextView()
    let footerNote = NSTextField(labelWithString: "")
    let copiedLabel = NSTextField(labelWithString: "")
    let copyButton = NSButton()
    let closeButton = NSButton()
    var onCopy: @MainActor () -> Void = {}
    var onClose: @MainActor () -> Void = {}
    private let hintBand = NSView()
    private var shownTable: RecognisedTable?

    init(result: RecognisedTableResult, sourceImage: CGImage?) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = String(localized: "Recognise Table")
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = false
        contentMinSize = Self.minimumContentSize
        setAccessibilityIdentifier("table.result.panel")
        build(sourceImage: sourceImage)
        update(result)
    }

    /// The count line: 「表格已识别 · 共 7 行、4 列（含表头） · DeepSeek」.
    static func status(for result: RecognisedTableResult) -> String {
        // Singular and plural are separate keys (English only has the two), so the line reads right wherever the
        // catalogue's plural rules are not loaded.
        let rowCount = Int64(result.table.rowCount), columnCount = Int64(result.table.columnCount)
        let rows = rowCount == 1 ? String(localized: "\(rowCount) row") : String(localized: "\(rowCount) rows")
        let columns = columnCount == 1
            ? String(localized: "\(columnCount) column") : String(localized: "\(columnCount) columns")
        let format = result.table.firstRowIsHeader
            ? String(localized: "Table recognised · %@, %@ (including header) · %@")
            : String(localized: "Table recognised · %@, %@ · %@")
        return String(format: format, rows, columns, result.serviceName)
    }

    func update(_ result: RecognisedTableResult) {
        statusLabel.stringValue = Self.status(for: result)
        if shownTable != result.table {
            shownTable = result.table
            tableText.textStorage?.setAttributedString(Self.attributed(result.table))
            tableText.setAccessibilityLabel(Self.status(for: result))
        }
        copiedLabel.isHidden = !result.copied
    }

    override func cancelOperation(_ sender: Any?) { closeButton.performClick(sender) }

    /// Every way the panel closes (Close, Esc, the title-bar button, ⌘W) runs `onClose` once (#874 fix1 WI-3).
    override func close() {
        let handler = onClose
        onClose = {}
        super.close()
        handler()
    }

    @objc private func copyTable(_ sender: Any?) { onCopy() }
    @objc private func closePanel(_ sender: Any?) { close() }

    // MARK: - Layout (state 41 `.panel`)

    private func build(sourceImage: CGImage?) {
        let content = NSView()
        contentView = content
        content.wantsLayer = true
        content.layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor

        // header { padding: 12px 16px } · .st muted 12px
        label(statusLabel, color: DesignColor.textSecondary.nsColor)
        statusLabel.setAccessibilityIdentifier("table.result.status")
        let headerRule = rule()
        // .hint { padding: 7px 16px; background: accent-soft; color: accent-text; 12px }
        hintBand.wantsLayer = true
        hintBand.layer?.backgroundColor = DesignColor.selectionFill.nsColor.cgColor
        label(hintLabel, color: DesignColor.selectionText.nsColor)
        hintLabel.stringValue = String(localized: "Check the text and the rows and columns.")
        hintBand.addSubview(hintLabel)
        // .src { width 230; padding 12; background surface; border-right subtle } · small 原图 muted
        sourceColumn.wantsLayer = true
        sourceColumn.layer?.backgroundColor = DesignColor.sidebarBackground.nsColor.cgColor
        label(sourceCaption, color: DesignColor.textSecondary.nsColor)
        sourceCaption.stringValue = String(localized: "Original")
        sourceImageView.imageScaling = .scaleProportionallyUpOrDown
        sourceImageView.imageAlignment = .alignTop
        sourceImageView.image = sourceImage.map { NSImage(cgImage: $0, size: .zero) }
        sourceImageView.setAccessibilityLabel(String(localized: "Original"))
        sourceColumn.addSubview(sourceCaption)
        sourceColumn.addSubview(sourceImageView)
        let sourceRule = rule()
        // .tbl { padding: 12px 14px; overflow: auto }
        tableText.isEditable = false
        tableText.isSelectable = true
        tableText.drawsBackground = false
        tableText.textContainerInset = NSSize(width: 14, height: 12)
        tableText.isVerticallyResizable = true
        tableText.isHorizontallyResizable = false
        tableText.autoresizingMask = [.width]
        tableText.minSize = .zero
        tableText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tableText.textContainer?.widthTracksTextView = true
        tableText.setAccessibilityIdentifier("table.result.table")
        tableScroll.documentView = tableText
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        let footerRule = rule()
        // footer { padding: 10px 16px; gap: 8px } · note muted 12px · 拷贝表格 primary · 关闭
        label(footerNote, color: DesignColor.textSecondary.nsColor)
        footerNote.stringValue = String(localized: "Pasted into Word it is a complete table; pasted as plain text it is tab-separated text.")
        footerNote.lineBreakMode = .byTruncatingTail
        footerNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label(copiedLabel, color: DesignColor.textPrimary.nsColor)
        copiedLabel.stringValue = String(localized: "Table copied")
        copiedLabel.isHidden = true
        copiedLabel.setAccessibilityIdentifier("table.result.copied")
        button(copyButton, String(localized: "Copy Table"), key: "\r", action: #selector(copyTable(_:)))
        copyButton.setAccessibilityIdentifier("table.result.copy")
        button(closeButton, String(localized: "Close"), key: "\u{1b}", action: #selector(closePanel(_:)))
        closeButton.setAccessibilityIdentifier("table.result.close")

        for view in [statusLabel, headerRule, hintBand, sourceColumn, sourceRule, tableScroll, footerRule,
                     footerNote, copiedLabel, copyButton, closeButton] {
            content.addSubview(view)
        }
        for view in [statusLabel, headerRule, hintBand, hintLabel, sourceColumn, sourceCaption, sourceImageView,
                     sourceRule, tableScroll, footerRule, footerNote, copiedLabel, copyButton, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let imageAspect = sourceImage.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 0
        let imageHeight = sourceImageView.heightAnchor.constraint(equalTo: sourceImageView.widthAnchor,
                                                                  multiplier: imageAspect)
        imageHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            headerRule.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            headerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            hintBand.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            hintBand.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hintBand.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: hintBand.topAnchor, constant: 7),
            hintLabel.bottomAnchor.constraint(equalTo: hintBand.bottomAnchor, constant: -7),
            hintLabel.leadingAnchor.constraint(equalTo: hintBand.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintBand.trailingAnchor, constant: -16),
            sourceColumn.topAnchor.constraint(equalTo: hintBand.bottomAnchor),
            sourceColumn.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sourceColumn.widthAnchor.constraint(equalToConstant: Self.sourceColumnWidth),
            sourceColumn.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            sourceCaption.topAnchor.constraint(equalTo: sourceColumn.topAnchor, constant: 12),
            sourceCaption.leadingAnchor.constraint(equalTo: sourceColumn.leadingAnchor, constant: 12),
            sourceImageView.topAnchor.constraint(equalTo: sourceCaption.bottomAnchor, constant: 6),
            sourceImageView.leadingAnchor.constraint(equalTo: sourceColumn.leadingAnchor, constant: 12),
            sourceImageView.trailingAnchor.constraint(equalTo: sourceColumn.trailingAnchor, constant: -12),
            sourceImageView.bottomAnchor.constraint(lessThanOrEqualTo: sourceColumn.bottomAnchor, constant: -12),
            imageHeight,
            sourceRule.topAnchor.constraint(equalTo: sourceColumn.topAnchor),
            sourceRule.bottomAnchor.constraint(equalTo: sourceColumn.bottomAnchor),
            sourceRule.trailingAnchor.constraint(equalTo: sourceColumn.trailingAnchor),
            sourceRule.widthAnchor.constraint(equalToConstant: 1),
            tableScroll.topAnchor.constraint(equalTo: hintBand.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: sourceColumn.trailingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerRule.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -10),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            copiedLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            copiedLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            footerNote.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footerNote.trailingAnchor.constraint(lessThanOrEqualTo: copiedLabel.leadingAnchor, constant: -8),
            footerNote.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
        // Keyboard: Copy Table first (the main action, Return), then Close (Esc), then the table; Tab cycles.
        copyButton.nextKeyView = closeButton
        closeButton.nextKeyView = tableText
        tableText.nextKeyView = copyButton
        initialFirstResponder = copyButton
    }

    private func label(_ field: NSTextField, color: NSColor) {
        field.font = DesignMetrics.font("uiSmall")
        field.textColor = color
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
    }

    private func button(_ button: NSButton, _ title: String, key: String, action: Selector) {
        button.title = title
        button.bezelStyle = .push
        button.keyEquivalent = key
        button.target = self
        button.action = action
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func rule() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = DesignColor.dividerSubtle.nsColor.cgColor
        return view
    }


    // MARK: - The table (state 41 `table`: 1 px borders, 5 × 7 padding, 12 pt, header row semibold on surface)

    /// Controlled content only: each cell is plain text in a text-table block; nothing from the reply is read as
    /// markup, a link or an image.
    static func attributed(_ table: RecognisedTable) -> NSAttributedString {
        let textTable = NSTextTable()
        textTable.numberOfColumns = max(1, table.columnCount)
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.setContentWidth(100, type: .percentageValueType)
        let output = NSMutableAttributedString()
        for (rowIndex, row) in table.rows.enumerated() {
            let header = table.firstRowIsHeader && rowIndex == 0
            for (columnIndex, cell) in row.enumerated() {
                let block = NSTextTableBlock(table: textTable, startingRow: rowIndex, rowSpan: 1,
                                             startingColumn: columnIndex, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(DesignColor.divider.nsColor)
                block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.verticalAlignment = .topAlignment
                if header { block.backgroundColor = DesignColor.sidebarBackground.nsColor }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineHeightMultiple = 1.2
                let font = NSFont.systemFont(ofSize: 12, weight: header ? .semibold : .regular)
                // An in-cell line break stays inside the cell.
                let text = cell.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\u{2028}")
                output.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: font, .foregroundColor: DesignColor.textPrimary.nsColor, .paragraphStyle: style,
                ]))
            }
        }
        return output
    }
}
