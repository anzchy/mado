import AppKit
import PicseeCore
import PicseeApplication

@MainActor private final class GridPhotoSurface: NSView {
    var onAppearanceChange: (() -> Void)?
    var onLayout: (() -> Void)?
    /// Drawn above the subviews' layers, which AppKit attaches after manually added sublayers.
    var overlayLayer: CALayer?
    override func layout() {
        super.layout()
        onLayout?()
        raiseOverlay()
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        raiseOverlay()
    }
    private func raiseOverlay() {
        guard let overlayLayer, let layer, layer.sublayers?.last !== overlayLayer else { return }
        layer.addSublayer(overlayLayer)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

@MainActor final class GridSortNoticeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A reused grid item contains only display data supplied by an authorized snapshot.
@MainActor public final class GridPhotoItem: NSCollectionViewItem {
    public private(set) var representedItemID: ItemID?
    public private(set) var filename = ""
    public private(set) var thumbnailToken = UUID()
    public private(set) var thumbnailGeneration: UInt64 = 0
    public private(set) var thumbnailPixelEdge = 0
    private(set) var thumbnailInstallCount = 0
    private(set) var thumbnailFailed = false
    var thumbnailHasImage: Bool { tile.layer?.contents != nil }
    private let tile = NSView()
    private let currentRing = CALayer()
    private let selectionOutline = CALayer()
    private let placeholder = NSTextField(labelWithString: String(localized: "Thumbnail pending"))
    private let nameLabel = NSTextField(labelWithString: "")
    private var showsName = true

    public override func loadView() {
        let surface = GridPhotoSurface(frame: NSRect(x: 0, y: 0, width: 220, height: 184))
        surface.onAppearanceChange = { [weak self] in self?.updateSelection() }
        surface.onLayout = { [weak self] in self?.layoutContent() }
        surface.wantsLayer = true
        // Page 11 `.thumbnail-wrap`: a quiet surface tile with the inner radius inside a transparent cell.
        tile.frame = NSRect(x: 4, y: 32, width: 212, height: 148)
        tile.wantsLayer = true
        tile.layer?.cornerRadius = DesignMetrics.radii["inner"]!
        tile.layer?.masksToBounds = true
        tile.layer?.contentsGravity = .resizeAspectFill
        placeholder.frame = tile.frame
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.maximumNumberOfLines = 1
        nameLabel.frame = NSRect(x: 4, y: 4, width: 212, height: 21)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.wantsLayer = true
        nameLabel.layer?.cornerRadius = DesignMetrics.radii["inner"]!
        // Selection stays at the tile edge; Current Item has a 2pt clear gap and 2pt stroke.
        // No ✓ badge at any selection count, by owner decision (#405, 1B); page 32 draws one on every selected cell.
        selectionOutline.borderWidth = 1
        selectionOutline.cornerRadius = DesignMetrics.radii["inner"]!
        selectionOutline.isHidden = true
        // Above the opaque tile's layer, which would otherwise cover the 1pt stroke (#405).
        selectionOutline.zPosition = 1
        surface.layer?.addSublayer(selectionOutline)
        surface.overlayLayer = selectionOutline
        currentRing.frame = tile.frame.insetBy(dx: -4, dy: -4)
        currentRing.cornerRadius = DesignMetrics.radii["inner"]! + 4
        currentRing.borderWidth = 2
        currentRing.isHidden = true
        surface.layer?.addSublayer(currentRing)
        surface.addSubview(tile)
        surface.addSubview(placeholder)
        surface.addSubview(nameLabel)
        surface.setAccessibilityRole(.button)
        view = surface
        layoutContent()
    }

    private func layoutContent() {
        guard isViewLoaded else { return }
        let width = max(0, view.bounds.width - 8)
        let height = max(0, view.bounds.height - (showsName ? 36 : 8))
        tile.frame = NSRect(x: 4, y: showsName ? 32 : 4, width: width, height: height)
        placeholder.frame = tile.frame
        nameLabel.frame = NSRect(x: 4, y: 4, width: width, height: 21)
        selectionOutline.frame = tile.frame
        currentRing.frame = tile.frame.insetBy(dx: -4, dy: -4)
    }

    var tileLayer: CALayer? { tile.layer }
    var isNameVisible: Bool { !nameLabel.isHidden }
    /// grid-display.html: Show File Names drops `.photo-name`; `.thumb-contain>img{object-fit:contain}` fits.
    func apply(_ options: GridDisplayOptions) {
        _ = view
        showsName = options.showFileNames
        nameLabel.isHidden = !options.showFileNames
        tile.layer?.contentsGravity = options.fit == .fit ? .resizeAspect : .resizeAspectFill
        layoutContent()
    }
    var currentRingLayer: CALayer { currentRing }
    /// Current Item (where arrows, Space and Enter act); distinct from Selection.
    public var isCurrent = false { didSet { updateSelection() } }
    public func configure(_ entry: FolderEntry) {
        thumbnailToken = UUID()
        tile.layer?.contents = nil
        placeholder.stringValue = String(localized: "Thumbnail pending")
        placeholder.isHidden = false
        thumbnailPixelEdge = 0
        thumbnailFailed = false
        representedItemID = entry.itemID
        filename = entry.url.lastPathComponent
        nameLabel.stringValue = filename
        view.setAccessibilityLabel("\(filename), \(String(localized: "thumbnail pending"))")
        view.setAccessibilityIdentifier("grid.cell")
        updateSelection()
    }

    public func beginThumbnail(generation: UInt64, pixelEdge: Int, token: UUID = UUID()) {
        thumbnailToken = token
        thumbnailGeneration = generation
        thumbnailPixelEdge = pixelEdge
        thumbnailFailed = false
        tile.layer?.contents = nil
        placeholder.stringValue = String(localized: "Thumbnail pending")
        placeholder.isHidden = false
        view.setAccessibilityLabel("\(filename), \(String(localized: "thumbnail pending"))")
    }

    @discardableResult public func installThumbnail(_ request: ImageDecodeRequest, image: DecodedImage,
        token: UUID, generation: UInt64, pixelEdge: Int) -> Bool {
        guard let key = request.renderKey,
              token == thumbnailToken, generation == thumbnailGeneration,
              pixelEdge == thumbnailPixelEdge, request.maximumPixelSize <= GridThumbnailPixelSizing.ceiling,
              key.maximumPixelSize == request.maximumPixelSize, key.itemID == representedItemID,
              image.itemID == key.itemID, image.revision == key.revision,
              image.image.width > 0, image.image.height > 0,
              image.image.width <= request.maximumPixelSize, image.image.height <= request.maximumPixelSize else { return false }
        tile.layer?.contents = image.image
        thumbnailFailed = false
        thumbnailInstallCount += 1
        placeholder.isHidden = true
        view.setAccessibilityLabel(filename)
        return true
    }

    public func thumbnailUnavailable(token: UUID) {
        guard token == thumbnailToken else { return }
        tile.layer?.contents = nil
        thumbnailFailed = true
        placeholder.stringValue = String(localized: "Thumbnail unavailable")
        placeholder.isHidden = false
        view.setAccessibilityLabel("\(filename), \(String(localized: "thumbnail unavailable"))")
    }

    public override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        guard isViewLoaded else { return }
        var accent = NSColor.clear.cgColor
        var fill = NSColor.clear.cgColor
        var surface = NSColor.clear.cgColor
        var ring = NSColor.clear.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ring = DesignColor.focusRing.nsColor.cgColor
            accent = DesignColor.accent.nsColor.cgColor
            fill = DesignColor.selectionFill.nsColor.cgColor
            surface = DesignColor.sidebarBackground.nsColor.cgColor
        }
        selectionOutline.borderColor = accent
        selectionOutline.isHidden = !isSelected
        tile.layer?.backgroundColor = surface
        currentRing.borderColor = ring
        currentRing.isHidden = !isCurrent
        // grid-light.html: the Current Item's name row carries the accent wash too, before anything is selected.
        nameLabel.layer?.backgroundColor = isSelected || isCurrent ? fill : NSColor.clear.cgColor
        // VoiceOver tells the Current Item apart from Selection; whole keys keep zh-Hans 「已选中，当前」 punctuation.
        view.setAccessibilityValue(isSelected && isCurrent ? String(localized: "Selected, Current")
            : isSelected ? String(localized: "Selected") : isCurrent ? String(localized: "Current") : "")
    }
}

/// grid-display.html `.grid-tools-panel`: Thumbnail Size, Show File Names, Thumbnails (Fill and Crop / Fit Entire Image).
public struct GridDisplayOptions: Equatable, Sendable {
    public var thumbnailSize: Double
    public var showFileNames: Bool
    public var fit: ThumbnailFit
    public init(thumbnailSize: Double = 220, showFileNames: Bool = true, fit: ThumbnailFit = .fill) {
        self.thumbnailSize = thumbnailSize; self.showFileNames = showFileNames; self.fit = fit
    }
    public init(_ preferences: DisplayPreferences) {
        self.init(thumbnailSize: preferences.thumbnailSize, showFileNames: preferences.showFileNames,
            fit: preferences.thumbnailFit)
    }
}

/// Page 11/12 inlined CSS: `.grid-scroll`, `.photo-grid`, `.photo-cell`,
/// `.thumbnail-wrap`, and `.layout-exploration .photo-name` (grid-light/dark.html).
private struct GridGeometry: Equatable {
    let columns: Int
    let itemSize: NSSize
    let columnGap: CGFloat
    let rowGap: CGFloat
    let horizontalInset: CGFloat
    let topInset: CGFloat = 16
    let tileHeight: CGFloat

    init(viewportWidth width: CGFloat, contentWidth: CGFloat, options: GridDisplayOptions = GridDisplayOptions()) {
        let narrow = width <= 1050
        let wide = width >= 1600
        horizontalInset = narrow ? 16 : (wide ? 32 : 24)
        columnGap = narrow ? 12 : (wide ? 22 : 16)
        rowGap = narrow ? 12 : (wide ? 22 : 18)
        // grid-display.html: Thumbnail Size sets `--thumb-min`; the ≤720 rule keeps 145.
        let minColumnWidth: CGFloat = width <= 720 ? 145 : CGFloat(options.thumbnailSize)
        let available = max(0, contentWidth - 2 * horizontalInset)
        columns = width <= 480 ? 1 : max(1, Int((available + columnGap) / (minColumnWidth + columnGap)))
        // Leave one representable step of slack so flow layout does not wrap an exact-fit row.
        let cellWidth = max(0, ((available - CGFloat(columns - 1) * columnGap) / CGFloat(columns)).nextDown)
        if width <= 720 { tileHeight = 150 }
        else {
            let baseline: CGFloat
            if narrow { baseline = 165 }
            else if wide { baseline = 200 }
            else { baseline = min(225, max(135, width * 0.147)) }
            tileHeight = baseline * CGFloat(options.thumbnailSize) / 220
        }
        // Cell padding 4+4; name margin 7, padded line 21, bottom padding 4. Without names only the padding stays.
        itemSize = NSSize(width: cellWidth, height: tileHeight + (options.showFileNames ? 36 : 8))
    }
}

private enum GridPageMove {
    case page(Int), first, last
}

@MainActor private final class GridCollectionView: NSCollectionView, NSUserInterfaceValidations {
    var onArrow: ((Int, SelectionModifier) -> Void)?
    var onPageOrEdge: ((GridPageMove, Bool) -> Void)?
    var onClick: ((Int?, SelectionModifier) -> Void)?
    var onNativeSelectionChange: (() -> Void)?
    var columnStep = 1
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, !event.modifierFlags.contains(.control) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let modifier: SelectionModifier = event.modifierFlags.contains(.shift) ? .shift
            : event.modifierFlags.contains(.command) ? .command : .plain
        onClick?(indexPathForItem(at: point)?.item, modifier)
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        let preserveSelection = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        switch event.keyCode {
        case 116: onPageOrEdge?(.page(-1), preserveSelection); return
        case 121: onPageOrEdge?(.page(1), preserveSelection); return
        case 115: onPageOrEdge?(.first, preserveSelection); return
        case 119: onPageOrEdge?(.last, preserveSelection); return
        default: break
        }
        let delta: Int
        switch event.keyCode {
        case 123: delta = -1
        case 124: delta = 1
        case 125: delta = columnStep
        case 126: delta = -columnStep
        default: super.keyDown(with: event); return
        }
        let modifier: SelectionModifier = event.modifierFlags.contains(.command) ? .command
            : event.modifierFlags.contains(.shift) ? .shift : .plain
        onArrow?(delta, modifier)
    }
    // Select All has no defined P3-09 model semantics; keep the native responder action inert.
    override func selectAll(_ sender: Any?) {}
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        if action == #selector(selectAll(_:)) { return false }
        return responds(to: action)
    }
    override func selectItems(at indexPaths: Set<IndexPath>, scrollPosition: NSCollectionView.ScrollPosition) {
        super.selectItems(at: indexPaths, scrollPosition: scrollPosition)
        onNativeSelectionChange?()
    }
}

/// Data source retains identity separately from position; native collection view handles reuse.
@MainActor public final class GridBrowserView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    public private(set) var collectionView: NSCollectionView = GridCollectionView()
    public private(set) var currentItemID: ItemID? {
        didSet {
            drawCurrent()
            onCurrentFileChange?(currentItemID.flatMap { entry(for: $0) }?.url.lastPathComponent)
        }
    }
    public var onCurrentFileChange: ((String?) -> Void)?
    public var onSelect: ((ItemID) -> Void)?
    public var onSelectionGesture: ((ItemID, SelectionModifier) -> BrowserSelection)?
    public var onClearSelection: (() -> BrowserSelection)?
    public var onDeselect: (() -> Void)?
    /// The grid's Current Item changed without a selection (entry, Esc return, removal fallback).
    public var onCurrentChange: ((ItemID) -> Void)?
    private let scrollView = NSScrollView()
    var bottomContentInset: CGFloat = 0 {
        didSet {
            guard bottomContentInset != oldValue else { return }
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomContentInset, right: 0)
        }
    }
    let metadataSortNotice = GridSortNoticeLabel(labelWithString: String(localized: "Sort unfinished"))
    private var displayedMetadataSortState: MetadataSortState = .idle
    private var entries: [FolderEntry] = []
    private var indices: [ItemID: Int] = [:]
    private var updating = false
    public private(set) var selection = BrowserSelection()
    private var geometry: GridGeometry?
    private let thumbnailScheduler = GridThumbnailScheduler()
    /// #146 GridFirstThumbnails: complete snapshot shown → every visible cell terminal. Signposts only.
    public var thumbnailTrace: (any GridThumbnailTracing)? = SignpostGridThumbnailTrace()
    /// The generation whose interval is still open, and the last one an interval began for; only a new read
    /// (an incomplete snapshot) or a cleared presentation lets the same generation begin again.
    private var firstThumbnailsPending: UInt64?
    private var firstThumbnailsBegun: UInt64?
    public var thumbnailPinning: (any ImagePresentationPinning)? {
        get { thumbnailScheduler.pinning }
        set { thumbnailScheduler.pinning = newValue }
    }
    public var thumbnailPrefetchResumption: (any PrefetchResuming)? {
        get { thumbnailScheduler.prefetchResumption }
        set { thumbnailScheduler.prefetchResumption = newValue }
    }
    public var thumbnailLoader: (@Sendable (FolderEntry, AccessRootID, ThumbnailCoverage, DecodePriority) async throws -> (ImageDecodeRequest, DecodedImage))? {
        didSet { reconcileThumbnails() }
    }
    public var displayOptions = GridDisplayOptions() {
        didSet {
            guard displayOptions != oldValue else { return }
            updateGeometry()
            collectionView.layoutSubtreeIfNeeded()
            for case let item as GridPhotoItem in collectionView.visibleItems() { item.apply(displayOptions) }
            if displayOptions.thumbnailSize != oldValue.thumbnailSize,
               let currentItemID, let index = indices[currentItemID] {
                scrollIntoView(index, aligningToBackingPixels: true)
            }
            reconcileThumbnails()
        }
    }
    private var thumbnailsActive = false
    private var thumbnailGeneration: UInt64 = 0
    private static let reuseID = NSUserInterfaceItemIdentifier("grid.photo")

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 220, height: 184)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 16, left: 24, bottom: 30, right: 24)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [DesignColor.canvasBackground.nsColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        (collectionView as? GridCollectionView)?.onArrow = { [weak self] delta, modifier in
            self?.moveCurrent(by: delta, preservingSelection: modifier != .plain, extendingRange: modifier == .shift)
        }
        (collectionView as? GridCollectionView)?.onPageOrEdge = { [weak self] move, preserveSelection in
            self?.moveCurrent(move, preservingSelection: preserveSelection)
        }
        (collectionView as? GridCollectionView)?.onClick = { [weak self] index, modifier in
            self?.clickItem(at: index, modifier: modifier)
        }
        (collectionView as? GridCollectionView)?.onNativeSelectionChange = { [weak self] in
            guard let self, !self.updating else { return }
            self.synchronizeSelection(self.selection)
        }
        collectionView.register(GridPhotoItem.self, forItemWithIdentifier: Self.reuseID)
        collectionView.setAccessibilityIdentifier("grid.collection")
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.backgroundColor = DesignColor.canvasBackground.nsColor
        scrollView.documentView = collectionView
        addSubview(scrollView)
        metadataSortNotice.isHidden = true
        metadataSortNotice.font = .systemFont(ofSize: 12, weight: .medium)
        metadataSortNotice.textColor = .secondaryLabelColor
        metadataSortNotice.wantsLayer = true
        refreshMetadataNoticeAppearance()
        metadataSortNotice.setAccessibilityIdentifier("folder.sort.pending")
        metadataSortNotice.setAccessibilityLabel(String(localized: "Sort unfinished"))
        addSubview(metadataSortNotice)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        thumbnailScheduler.onResult = { [weak self] index, request, image in
            self?.showThumbnail(at: index, request: request, image: image)
            self?.checkFirstThumbnails()
        }
        thumbnailScheduler.onFailure = { [weak self] index in
            self?.showThumbnailFailure(at: index)
            self?.checkFirstThumbnails()
        }
        updateGeometry()
    }
    public required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func clipFrameChanged() {
        updateGeometry()
        reconcileThumbnails()
    }

    @objc private func clipBoundsChanged() { reconcileThumbnails() }

    @objc private func scrollerStyleChanged() {
        scrollView.tile()
        updateGeometry()
    }

    public override func layout() {
        super.layout()
        metadataSortNotice.sizeToFit()
        metadataSortNotice.frame.origin = NSPoint(x: max(12, bounds.maxX - metadataSortNotice.frame.width - 20), y: 12)
        updateGeometry()
        reconcileThumbnails()
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMetadataNoticeAppearance()
    }
    private func refreshMetadataNoticeAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            metadataSortNotice.layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
        }
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
        needsLayout = true
    }
    public func setMetadataSortPending(_ pending: Bool) {
        setMetadataSortState(pending ? .pending : .idle)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconcileThumbnails()
    }

    public func setThumbnailsActive(_ active: Bool) {
        thumbnailsActive = active
        if active { reconcileThumbnails() } else {
            if firstThumbnailsPending != nil { endFirstThumbnails(.stopped) }
            thumbnailScheduler.stop()
        }
    }

    public func stopThumbnails() { setThumbnailsActive(false) }
    /// Revoke visible content as well as scheduled work; a hidden collection must
    /// not retain an accessible filename or thumbnail from a lost root.
    public func clearPresentation() {
        stopThumbnails()
        firstThumbnailsBegun = nil
        thumbnailGeneration &+= 1
        entries = []; indices = [:]; currentItemID = nil
        selection = BrowserSelection()
        updating = true
        collectionView.reloadData()
        collectionView.deselectAll(nil)
        updating = false
        setMetadataSortState(.idle)
    }
    /// Drops prefetched thumbnails under memory pressure and requests them again once it ends.
    public func setMemoryPressure(_ active: Bool) {
        thumbnailScheduler.setMemoryPressure(active)
        reconcileThumbnails()
    }
    func waitForThumbnail(at index: Int) async { await thumbnailScheduler.waitForTerminal(at: index) }
    /// Read-only: the cell's request ended with a thumbnail or a failure.
    func thumbnailIsTerminal(at index: Int) -> Bool {
        thumbnailScheduler.result(at: index) != nil || thumbnailScheduler.hasFailure(at: index)
    }

    private var thumbnailCoverage: ThumbnailCoverage {
        guard let geometry else { return ThumbnailCoverage(width: 0, height: 0) }
        let scale: CGFloat
        if let window { scale = window.backingScaleFactor } else { scale = 1 }
        return GridThumbnailPixelSizing.coverage(tile: NSSize(width: geometry.itemSize.width - 8,
            height: geometry.tileHeight), backingScale: scale)
    }
    private var thumbnailPixelEdge: Int { thumbnailCoverage.fallbackEdge }

    private func reconcileThumbnails() {
        guard thumbnailsActive, window != nil, let geometry, thumbnailLoader != nil else {
            thumbnailScheduler.reconcile(visible: [], columns: 1, coverage: ThumbnailCoverage(width: 0, height: 0), loader: nil)
            return
        }
        let visible = visibleIndices()
        thumbnailScheduler.reconcile(visible: visible, columns: geometry.columns,
            coverage: thumbnailCoverage, loader: thumbnailLoader)
        for index in visible { bindThumbnail(at: index) }
        checkFirstThumbnails()
    }

    private func visibleIndices() -> Set<Int> {
        // The flow layout is installed in init and remains this view's layout.
        let attributes = collectionView.collectionViewLayout!.layoutAttributesForElements(in: collectionView.visibleRect)
        var visible: Set<Int> = []
        for attribute in attributes where attribute.representedElementCategory == .item {
            if let index = attribute.indexPath?.item { visible.insert(index) }
        }
        return visible
    }

    private func firstThumbnailCounts(_ visible: Set<Int>) -> (shown: Int, failed: Int) {
        (visible.filter { thumbnailScheduler.result(at: $0) != nil }.count,
         visible.filter { thumbnailScheduler.hasFailure(at: $0) }.count)
    }

    private func endFirstThumbnails(_ outcome: GridFirstThumbnailsOutcome) {
        guard let generation = firstThumbnailsPending else { return }
        firstThumbnailsPending = nil
        let visible = visibleIndices()
        let counts = firstThumbnailCounts(visible)
        thumbnailTrace?.firstThumbnailsEnd(generation: generation, outcome: outcome, visible: visible.count,
                                           shown: counts.shown, failed: counts.failed)
    }

    /// Ends the interval the first time every visible cell is terminal. A grid that is inactive, outside a window,
    /// hidden or not yet laid out has no visible cells and keeps waiting.
    private func checkFirstThumbnails() {
        guard firstThumbnailsPending != nil, thumbnailsActive, window != nil else { return }
        let visible = visibleIndices()
        let counts = firstThumbnailCounts(visible)
        guard !visible.isEmpty, counts.shown + counts.failed == visible.count else { return }
        endFirstThumbnails(.complete)
    }

    private func bindThumbnail(at index: Int) {
        guard entries.indices.contains(index), let token = thumbnailScheduler.token(at: index),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridPhotoItem,
              item.representedItemID == entries[index].itemID else { return }
        let edge = thumbnailPixelEdge
        if item.thumbnailToken != token || item.thumbnailGeneration != thumbnailGeneration || item.thumbnailPixelEdge != edge {
            item.beginThumbnail(generation: thumbnailGeneration, pixelEdge: edge, token: token)
        }
        if let (request, image) = thumbnailScheduler.result(at: index), !item.thumbnailHasImage {
            _ = item.installThumbnail(request, image: image, token: token,
                generation: thumbnailGeneration, pixelEdge: edge)
        } else if thumbnailScheduler.shouldDisplayFailure(at: index), !item.thumbnailFailed {
            item.thumbnailUnavailable(token: token)
        }
    }

    private func showThumbnail(at index: Int, request: ImageDecodeRequest, image: DecodedImage) {
        guard entries.indices.contains(index), let token = thumbnailScheduler.token(at: index),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridPhotoItem,
              item.representedItemID == entries[index].itemID else { return }
        _ = item.installThumbnail(request, image: image, token: token,
            generation: thumbnailGeneration, pixelEdge: thumbnailPixelEdge)
    }

    private func showThumbnailFailure(at index: Int) {
        guard let token = thumbnailScheduler.token(at: index),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? GridPhotoItem,
              entries.indices.contains(index), item.representedItemID == entries[index].itemID else { return }
        item.thumbnailUnavailable(token: token)
    }

    private func updateGeometry() {
        let viewportWidth = window?.contentView?.bounds.width ?? bounds.width
        let next = GridGeometry(viewportWidth: viewportWidth, contentWidth: scrollView.contentSize.width,
            options: displayOptions)
        guard next != geometry, let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        geometry = next
        (collectionView as? GridCollectionView)?.columnStep = next.columns
        layout.itemSize = next.itemSize
        layout.minimumInteritemSpacing = next.columnGap
        layout.minimumLineSpacing = next.rowGap
        layout.sectionInset = NSEdgeInsets(top: next.topInset, left: next.horizontalInset,
            bottom: 30, right: next.horizontalInset)
        layout.invalidateLayout()
    }

    public func display(_ snapshot: FolderSnapshot, selectedItemID: ItemID?) {
        var next = BrowserSelection()
        if let selectedItemID { next.click(selectedItemID, in: snapshot.navigationEntries.map(\.itemID)) }
        display(snapshot, selection: next)
    }

    public func display(_ snapshot: FolderSnapshot, selection: BrowserSelection) {
        // Counts are taken before the scheduler forgets the old snapshot's results.
        if firstThumbnailsPending != nil, !snapshot.isComplete || firstThumbnailsPending != snapshot.version.generation {
            endFirstThumbnails(.superseded)
        }
        if !snapshot.isComplete { firstThumbnailsBegun = nil }
        thumbnailScheduler.setSnapshot(snapshot)
        thumbnailGeneration = snapshot.version.generation
        if !snapshot.isComplete {
            entries = []; indices = [:]; currentItemID = nil
            self.selection = BrowserSelection()
            updating = true
            collectionView.reloadData()
            collectionView.deselectAll(nil)
            updating = false
            reconcileThumbnails()
            return
        }
        entries = snapshot.navigationEntries
        indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.itemID, $0.offset) })
        self.selection = selection
        self.selection.reconcile(with: entries.map(\.itemID))
        if let selectedCurrent = self.selection.currentItemID { currentItemID = selectedCurrent }
        if let currentItemID, indices[currentItemID] == nil {
            self.currentItemID = entries.first?.itemID
            if let first = self.currentItemID { onCurrentChange?(first) }
        }
        updating = true
        collectionView.reloadData()
        drawSelection()
        updating = false
        if firstThumbnailsBegun != snapshot.version.generation {
            firstThumbnailsBegun = snapshot.version.generation
            firstThumbnailsPending = snapshot.version.generation
            thumbnailTrace?.firstThumbnailsBegin(generation: snapshot.version.generation, items: entries.count)
            if entries.isEmpty { endFirstThumbnails(.complete) }
        }
        reconcileThumbnails()
    }
    public func synchronizeSelection(_ selection: BrowserSelection) {
        self.selection = selection
        self.selection.reconcile(with: entries.map(\.itemID))
        if let current = self.selection.currentItemID { currentItemID = current }
        updating = true
        drawSelection()
        updating = false
    }
    private func drawSelection() {
        let paths = Set(selection.selectedItemIDs.compactMap { indices[$0] }
            .map { IndexPath(item: $0, section: 0) })
        collectionView.deselectAll(nil)
        if !paths.isEmpty { collectionView.selectItems(at: paths, scrollPosition: []) }
    }
    private func clickItem(at index: Int?, modifier: SelectionModifier) {
        guard let index, let id = itemID(at: index) else {
            if let onClearSelection { synchronizeSelection(onClearSelection()) }
            else { selection.clearSelection(); synchronizeSelection(selection) }
            return
        }
        if let onSelectionGesture {
            synchronizeSelection(onSelectionGesture(id, modifier))
        } else {
            selection.click(id, modifier: modifier, in: entries.map(\.itemID))
            synchronizeSelection(selection)
            onSelect?(id)
        }
    }
    /// A requested Current Item that is filtered out or gone falls back to the first item in sort order.
    public func activate(currentItemID: ItemID? = nil) {
        if let currentItemID { self.currentItemID = indices[currentItemID] != nil ? currentItemID : nil }
        if self.currentItemID.flatMap({ indices[$0] }) == nil { self.currentItemID = entries.first?.itemID }
        if let current = self.currentItemID { onCurrentChange?(current) }
        window?.makeFirstResponder(collectionView)
    }
    public func setCurrentItemID(_ id: ItemID?) {
        currentItemID = id.flatMap { indices[$0] != nil ? $0 : nil } ?? entries.first?.itemID
    }
    private func moveCurrent(_ move: GridPageMove, preservingSelection: Bool) {
        guard !entries.isEmpty, let geometry else { return }
        let current = currentItemID.flatMap { indices[$0] } ?? 0
        let delta: Int
        let includingUnchangedTarget: Bool
        switch move {
        case .first:
            delta = -current
            includingUnchangedTarget = true
        case .last:
            delta = entries.count - 1 - current
            includingUnchangedTarget = true
        case .page(let direction):
            let insets = scrollView.contentInsets
            let height = max(0, scrollView.contentView.documentVisibleRect.height - insets.top - insets.bottom)
            // Only the gaps between fitting rows count; even a short viewport advances one row.
            let rows = max(1, Int((height + geometry.rowGap) / (geometry.itemSize.height + geometry.rowGap)))
            delta = direction * rows * geometry.columns
            includingUnchangedTarget = false
        }
        moveCurrent(by: delta, preservingSelection: preservingSelection, includingUnchangedTarget: includingUnchangedTarget)
    }
    private func moveCurrent(by delta: Int, preservingSelection: Bool, includingUnchangedTarget: Bool = false,
                             extendingRange: Bool = false) {
        guard !entries.isEmpty else { return }
        let current = currentItemID.flatMap { indices[$0] } ?? 0
        let next = max(0, min(entries.count - 1, current + delta))
        guard includingUnchangedTarget || next != current || currentItemID == nil, let id = itemID(at: next) else { return }
        // Continue only an anchored interval. Arbitrary picked sets keep their focus-only navigation.
        let extendsAnchoredRange: Bool
        if extendingRange, let anchorID = selection.anchorItemID, let anchor = indices[anchorID],
           selection.currentItemID == currentItemID {
            let interval = Set(entries[min(anchor, current)...max(anchor, current)].map(\.itemID))
            extendsAnchoredRange = selection.selectedItemIDs == interval
        } else {
            extendsAnchoredRange = false
        }
        currentItemID = id
        if extendsAnchoredRange {
            clickItem(at: next, modifier: .shift)
        } else if preservingSelection {
            selection.focus(id, in: entries.map(\.itemID))
            onCurrentChange?(id)
        } else {
            selection.click(id, in: entries.map(\.itemID))
            onSelect?(id)
        }
        updating = true
        drawSelection()
        updating = false
        scrollIntoView(next)
    }
    /// Finder-style: scroll the least distance that shows the whole tile, none when it is already visible.
    /// Exact, not `scrollToVisible`: that rounds to whole points and leaves fractional-height rows clipped.
    private func scrollIntoView(_ index: Int, aligningToBackingPixels: Bool = false) {
        let tile = collectionView.frameForItem(at: index)
        // The clip includes area under content insets (a bar over the grid); the tile must clear it.
        let insets = scrollView.contentInsets
        var visible = scrollView.contentView.documentVisibleRect
        visible.origin.y += insets.top
        visible.size.height -= insets.top + insets.bottom
        var origin = scrollView.contentView.bounds.origin
        let movingUp = tile.minY < visible.minY
        if movingUp { origin.y += tile.minY - visible.minY }
        else if tile.maxY > visible.maxY { origin.y += tile.maxY - visible.maxY }
        else { return }
        // A titled window's clip view aligns its origin to backing pixels. During a size change,
        // rounding toward the hidden edge can leave a fractional sliver under the Bottom Bar.
        if aligningToBackingPixels {
            let scale = window?.backingScaleFactor ?? 1
            origin.y = (movingUp ? floor(origin.y * scale) : ceil(origin.y * scale)) / scale
        }
        restoreContentOffset(origin)
    }
    private func drawCurrent() {
        for case let item as GridPhotoItem in collectionView.visibleItems() {
            item.isCurrent = item.representedItemID != nil && item.representedItemID == currentItemID
        }
    }
    public func itemID(at index: Int) -> ItemID? { entries.indices.contains(index) ? entries[index].itemID : nil }
    public var displayedItemIDs: [ItemID] { entries.map(\.itemID) }
    public func index(for id: ItemID) -> Int? { indices[id] }
    public func entry(for id: ItemID) -> FolderEntry? { indices[id].map { entries[$0] } }
    public var contentOffset: NSPoint { scrollView.contentView.bounds.origin }
    public func restoreContentOffset(_ point: NSPoint) {
        scrollView.contentView.setBoundsOrigin(point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    /// Reveal the whole tile with minimum movement, preserving the viewport when already visible.
    public func reveal(_ id: ItemID) {
        guard let index = indices[id] else { return }
        scrollIntoView(index)
    }
    public func scrollTo(_ id: ItemID) {
        guard let index = indices[id] else { return }
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .top)
    }
    public func firstVisibleItemID() -> ItemID? {
        collectionView.visibleItems().compactMap { item in collectionView.indexPath(for: item)?.item }
            .min().flatMap { itemID(at: $0) }
    }
    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.reuseID, for: indexPath)
        if let photo = item as? GridPhotoItem {
            photo.apply(displayOptions)
            photo.configure(entries[indexPath.item])
            photo.isSelected = selection.selectedItemIDs.contains(entries[indexPath.item].itemID)
            photo.isCurrent = entries[indexPath.item].itemID == currentItemID
            if let token = thumbnailScheduler.token(at: indexPath.item) {
                let edge = thumbnailPixelEdge
                photo.beginThumbnail(generation: thumbnailGeneration, pixelEdge: edge, token: token)
                if let (request, image) = thumbnailScheduler.result(at: indexPath.item) {
                    _ = photo.installThumbnail(request, image: image, token: token,
                        generation: thumbnailGeneration, pixelEdge: edge)
                } else if thumbnailScheduler.shouldDisplayFailure(at: indexPath.item) {
                    photo.thumbnailUnavailable(token: token)
                }
            }
        }
        return item
    }
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !updating else { return }
        if collectionView.selectionIndexPaths.count <= 1,
           let index = indexPaths.first?.item, let id = itemID(at: index) {
            selection.click(id, in: entries.map(\.itemID))
            currentItemID = id
            onSelect?(id)
        }
        synchronizeSelection(selection)
    }
    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !updating else { return }
        if collectionView.selectionIndexPaths.isEmpty {
            selection.clearSelection()
            onDeselect?()
        }
        synchronizeSelection(selection)
    }
}
