import AppKit
import ImageIO
import os

/// The Home's Image Wall: decorative only, never hit, never an accessibility element.
@MainActor private final class FirstLaunchWallView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class FirstLaunchView: NSView {
    static func sampleURL(name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "jpg")
    }
    let openButton: ViewerStateButton
    private let dropArea = NSView()
    private let dropOutline = CAShapeLayer()
    private let wall = FirstLaunchWallView()
    private let tilesLayer = CALayer()
    private let scrim = CAGradientLayer()
    private var tiles: [CALayer] = []
    private let heading = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let shortcutKey = NSTextField(labelWithString: "⌘O")
    private let sampleURLs: [String: URL]?
    private(set) var sampleLoadCompleted = false
    private var dragActive = false
    var themeOverride: DesignTheme?
    var reduceMotionOverride: Bool?
    var reduceTransparencyOverride: Bool? { didSet { refreshStyle() } }
    /// #316 drift inputs; tests replace them, the App keeps the defaults.
    var windowVisible: @MainActor (NSWindow) -> Bool = FirstLaunchDrift.windowIsVisible
    var appFrontmost: @MainActor () -> Bool = FirstLaunchDrift.appIsFrontmost
    var driftClock: () -> CFTimeInterval = CACurrentMediaTime
    private static let driftKey = "first-launch.wall.drift"
    private static let driftLog = OSLog(subsystem: "io.github.anzchy.mado", category: "home")
    private var driftElapsed: CFTimeInterval = 0
    private var driftRunningSince: CFTimeInterval?
    private var tilesRest = CGPoint.zero
    var semanticViews: [NSView] { [heading, openButton, shortcut] }
    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var reduceTransparency: Bool { reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    private var theme: DesignTheme {
        themeOverride ?? (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
    }
    init(frame: NSRect, openButton: ViewerStateButton, sampleURLs: [String: URL]? = nil) {
        self.openButton = openButton
        self.sampleURLs = sampleURLs
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        setAccessibilityElement(false)
        wall.wantsLayer = true
        wall.layer?.masksToBounds = true
        wall.unregisterDraggedTypes()
        wall.setAccessibilityElement(false)
        wall.setAccessibilityHidden(true)
        wall.setAccessibilityIdentifier("first-launch.wall")
        tilesLayer.name = "first-launch.wall.tiles"
        for tile in FirstLaunchLayout.wall(in: frame.size).tiles {
            let container = CALayer()
            container.name = tile.sample
            container.isHidden = true
            let image = CALayer()
            image.masksToBounds = true
            image.contentsGravity = .resizeAspectFill
            container.addSublayer(image)
            let ring = CALayer()
            ring.name = "first-launch.wall.ring"
            container.addSublayer(ring)
            tilesLayer.addSublayer(container)
            tiles.append(container)
        }
        scrim.name = "first-launch.wall.scrim"
        scrim.type = .radial
        scrim.locations = [0, 0.45, 1]
        scrim.startPoint = CGPoint(x: 0.5, y: 0.5)
        scrim.endPoint = CGPoint(x: 0.92, y: 0.88)
        wall.layer?.addSublayer(tilesLayer)
        wall.layer?.addSublayer(scrim)
        addSubview(wall)
        dropArea.wantsLayer = true
        dropArea.setAccessibilityElement(false)
        dropArea.setAccessibilityIdentifier("first-launch.drop")
        dropOutline.fillColor = NSColor.clear.cgColor
        dropOutline.lineWidth = 1.5
        dropOutline.lineDashPattern = [6, 4]
        dropArea.layer?.addSublayer(dropOutline)
        addSubview(dropArea)
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        heading.alignment = .center
        heading.setAccessibilityElement(true); heading.setAccessibilityRole(.staticText)
        heading.setAccessibilityIdentifier("first-launch.heading")
        shortcut.font = .systemFont(ofSize: 13)
        shortcut.alignment = .left
        shortcut.setAccessibilityElement(true); shortcut.setAccessibilityRole(.staticText)
        shortcut.setAccessibilityIdentifier("first-launch.shortcut")
        shortcut.lineBreakMode = .byClipping
        shortcutKey.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutKey.alignment = .center
        shortcutKey.wantsLayer = true
        shortcutKey.setAccessibilityElement(false)
        shortcutKey.setAccessibilityIdentifier("first-launch.shortcut-key")
        addSubview(heading); addSubview(openButton); addSubview(shortcut); addSubview(shortcutKey)
        refreshStyle()
        loadSamples()
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(accessibilityOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    required init?(coder: NSCoder) { nil }
    @objc private func accessibilityOptionsChanged(_ notification: Notification) {
        refreshStyle()
        refreshDrift()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshStyle() }
    private static let windowDriftInputs = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                            NSWindow.didDeminiaturizeNotification]
    private static let appDriftInputs = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                         NSApplication.didHideNotification, NSApplication.didUnhideNotification]
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for name in Self.windowDriftInputs { NotificationCenter.default.removeObserver(self, name: name, object: window) }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        for name in Self.appDriftInputs { NotificationCenter.default.removeObserver(self, name: name, object: nil) }
    }
    /// Window notifications come only from the Home's own window; app ones only while the Home is in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for name in Self.windowDriftInputs {
                NotificationCenter.default.addObserver(self, selector: #selector(driftInputChanged(_:)), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
            for name in Self.appDriftInputs {
                NotificationCenter.default.addObserver(self, selector: #selector(driftInputChanged(_:)), name: name, object: nil)
            }
        }
        refreshDrift()
    }
    /// Every trigger re-reads all three inputs; the notification itself is not the state.
    @objc private func driftInputChanged(_ notification: Notification) { refreshDrift() }
    /// ⌘W orders a reusable window out with the Home still inside, and the window is still on screen when this
    /// arrives. Pause now; later triggers re-read the readers, which see the closed window as not visible.
    @objc private func windowWillClose(_ notification: Notification) { refreshDrift(closing: true) }
    override func viewDidHide() { super.viewDidHide(); refreshDrift() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshDrift() }
    /// Runs the drift while it may animate; otherwise freezes the tiles where they are. Running time is the only
    /// time that advances the ping-pong phase, so a resume continues from the paused offset.
    private func refreshDrift(closing: Bool = false) {
        let visible = !closing && (window.map { !isHiddenOrHasHiddenAncestor && windowVisible($0) } ?? false)
        let frontmost = appFrontmost()
        let stillness = reduceMotion
        let run = FirstLaunchDrift.mayAnimate(visible: visible, frontmost: frontmost, reduceMotion: stillness)
        // Debug-level transition trace for the device smoke: the three inputs only, nothing personal.
        if run == (driftRunningSince == nil) {
            os_log(.debug, log: Self.driftLog, "wall drift %{public}s visible=%{public}d frontmost=%{public}d reduceMotion=%{public}d",
                   run ? "run" : "pause", visible ? 1 : 0, frontmost ? 1 : 0, stillness ? 1 : 0)
        }
        if run, driftRunningSince == nil {
            let now = driftClock()
            driftRunningSince = now
            let drift = CABasicAnimation(keyPath: "position.y")
            drift.isAdditive = true
            drift.fromValue = 0
            drift.toValue = FirstLaunchDrift.range
            drift.duration = FirstLaunchDrift.period
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .linear)
            drift.preferredFrameRateRange = FirstLaunchDrift.frameRate
            drift.beginTime = now
            drift.timeOffset = driftElapsed
            placeTiles()
            tilesLayer.add(drift, forKey: Self.driftKey)
        } else if !run, let since = driftRunningSince {
            driftElapsed = (driftElapsed + driftClock() - since).truncatingRemainder(dividingBy: 2 * FirstLaunchDrift.period)
            driftRunningSince = nil
            tilesLayer.removeAnimation(forKey: Self.driftKey)
            placeTiles()
        }
    }
    /// The model sits at rest while the additive drift runs, and at the frozen offset while paused.
    private func placeTiles() {
        let offset = driftRunningSince == nil ? FirstLaunchDrift.offset(elapsed: driftElapsed) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tilesLayer.position = CGPoint(x: tilesRest.x, y: tilesRest.y + offset)
        CATransaction.commit()
    }
    private func refreshStyle(animateWall: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = DesignColor.canvasBackground.nsColor.usingColorSpace(.deviceRGB)!
            let border = DesignColor.divider.nsColor.usingColorSpace(.deviceRGB)!
            let tint = DesignColor.accent.nsColor.usingColorSpace(.deviceRGB)!
            heading.stringValue = dragActive ? String(localized: "Release to open") : String(localized: "Drop a photo folder here")
            shortcut.stringValue = String(localized: "or press ⌘O")
            heading.setAccessibilityLabel(heading.stringValue)
            shortcut.setAccessibilityLabel(shortcut.stringValue)
            // Page 21 `.is-drag-over [data-drop-prompt]`: `--color-accent-text`.
            heading.textColor = (dragActive ? DesignColor.selectionText : DesignColor.textPrimary).nsColor
            shortcut.textColor = DesignColor.textSecondary.nsColor
            openButton.bezelColor = DesignColor.primaryFill.nsColor
            openButton.contentTintColor = DesignColor.onPrimary.nsColor
            openButton.font = .systemFont(ofSize: 13, weight: .semibold)
            openButton.attributedTitle = NSAttributedString(string: openButton.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: DesignColor.onPrimary.nsColor,
            ])
            shortcutKey.textColor = DesignColor.textSecondary.nsColor
            shortcutKey.layer?.cornerRadius = 4
            shortcutKey.layer?.borderWidth = 1
            shortcutKey.layer?.borderColor = border.cgColor
            shortcutKey.layer?.backgroundColor = DesignColor.sidebarBackground.nsColor.cgColor
            dropArea.layer?.cornerRadius = 14
            dropOutline.isHidden = !dragActive
            dropOutline.strokeColor = tint.cgColor
            let backgroundBytes = DesignColor.canvasBackground.components(theme)
            let accentBytes = DesignColor.accent.components(theme)
            let opaqueDrop = NSColor(srgbRed: backgroundBytes[0] * 0.9 + accentBytes[0] * 0.1,
                                     green: backgroundBytes[1] * 0.9 + accentBytes[1] * 0.1,
                                     blue: backgroundBytes[2] * 0.9 + accentBytes[2] * 0.1, alpha: 1)
            dropArea.layer?.backgroundColor = dragActive
                ? (reduceTransparency ? opaqueDrop : DesignColor.selectionFill.nsColor).cgColor
                : NSColor.clear.cgColor
            styleWall()
            fadeWall(animated: animateWall)
            needsLayout = true
        }
    }
    func setDragActive(_ active: Bool) {
        guard dragActive != active else { return }
        dragActive = active
        refreshStyle(animateWall: true)
    }
    /// Page 21 `.is-drag-over .wall{opacity:.4}` with `transition: opacity var(--motion-duration-fast)` (150 ms);
    /// Reduce Transparency hides the wall during a drag, Reduce Motion drops the fade.
    private func fadeWall(animated: Bool) {
        guard let layer = wall.layer else { return }
        let target: CGFloat = dragActive ? (reduceTransparency ? 0 : 0.4) : 1
        let current = wall.alphaValue
        // Read the on-screen value before the model changes, so a reversal mid-fade starts where it is.
        let from = layer.presentation()?.opacity ?? Float(current)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wall.alphaValue = target
        CATransaction.commit()
        if animated && !reduceMotion && current != target {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = Float(target)
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "first-launch.wall.fade")
        } else if reduceMotion || current != target {
            layer.removeAnimation(forKey: "first-launch.wall.fade")
        }
    }
    /// Page 21: tiles carry `--home-wall-opacity`; each image carries `--radius-control` and `--shadow-soft`
    /// (the ring sits just outside the image, the drop shadow on its container).
    private func styleWall() {
        let dark = theme == .dark
        let text = DesignColor.textPrimary.components(theme)
        func colour(_ c: [Double], _ alpha: Double) -> CGColor { CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: alpha) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tilesLayer.opacity = dark ? 0.38 : 0.32
        // Page 21 `.wall::after`: `--color-bg` mixed with transparent at 100% / 80% / 25%.
        let background = DesignColor.canvasBackground.components(theme)
        scrim.colors = [1, 0.8, 0.25].map { colour(background, $0) }
        for container in tiles {
            container.shadowColor = dark ? colour([0, 0, 0], 1) : colour(text, 1)
            container.shadowOpacity = dark ? 0.45 : 0.08
            container.shadowOffset = CGSize(width: 0, height: -8)
            container.shadowRadius = 12
            guard let image = container.sublayers?.first, let ring = container.sublayers?.last else { continue }
            image.cornerRadius = 6
            // `--shadow-soft`'s first layer is an outer 0.5 spread, so the ring is 0.5 wide, radius 6.5,
            // outside the image edge; a border on the image itself would cover its edge pixels.
            ring.cornerRadius = 6.5
            ring.borderWidth = 0.5
            ring.borderColor = colour(text, dark ? 0.16 : 0.12)
        }
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let content = NSSize(width: w, height: max(0, h - 38))
        layoutWall(content)
        // Page 21 `.drop-outline`: inset 18 on all four sides of the content area, radius 14.
        dropArea.frame = NSRect(x: 18, y: 18, width: max(0, content.width - 36), height: max(0, content.height - 36))
        dropOutline.frame = dropArea.bounds
        dropOutline.path = CGPath(roundedRect: dropArea.bounds.insetBy(dx: 0.75, dy: 0.75),
                                  cornerWidth: 14, cornerHeight: 14, transform: nil)
        // The B4 centre stays at native point size when the window changes size; page 21 `.home-centre`:
        // the drop hint, an 18 pt gap, then the button row (#441: no chips row).
        let centreHeight: CGFloat = 24 + 18 + 30
        let centreTop = dropArea.frame.midY + centreHeight / 2
        heading.frame = NSRect(x: w / 2 - 240, y: centreTop - 24, width: 480, height: 24)
        let buttonWidth = ceil((openButton.title as NSString).size(withAttributes: [.font: openButton.font!]).width) + 28
        let shortcutPrefix = shortcut.stringValue.replacingOccurrences(of: "⌘O", with: "").trimmingCharacters(in: .whitespaces)
        let shortcutWidth = ceil((shortcutPrefix as NSString).size(withAttributes: [.font: shortcut.font!]).width)
        let keyWidth = ceil((shortcutKey.stringValue as NSString).size(withAttributes: [.font: shortcutKey.font!]).width) + 14
        let groupWidth = buttonWidth + 12 + shortcutWidth + 4 + keyWidth
        openButton.frame = NSRect(x: w / 2 - groupWidth / 2, y: heading.frame.minY - 18 - 30, width: buttonWidth, height: 30)
        shortcut.frame = NSRect(x: openButton.frame.maxX + 12, y: openButton.frame.midY - 9, width: shortcutWidth, height: 18)
        shortcutKey.frame = NSRect(x: shortcut.frame.maxX + 4, y: openButton.frame.midY - 9, width: keyWidth, height: 18)
    }
    private func layoutWall(_ size: NSSize) {
        wall.frame = NSRect(origin: .zero, size: size)
        let layout = FirstLaunchLayout.wall(in: size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tilesLayer.setAffineTransform(.identity)
        tilesLayer.bounds = CGRect(origin: .zero, size: layout.box.size)
        tilesRest = CGPoint(x: layout.box.midX, y: layout.box.midY)
        placeTiles()
        tilesLayer.setAffineTransform(CGAffineTransform(rotationAngle: FirstLaunchLayout.tiltDegrees * .pi / 180))
        for (container, tile) in zip(tiles, layout.tiles) {
            container.frame = tile.frame
            container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
            container.sublayers?.first?.frame = container.bounds
            container.sublayers?.last?.frame = container.bounds.insetBy(dx: -0.5, dy: -0.5)
        }
        scrim.frame = wall.bounds
        CATransaction.commit()
    }
    private func loadSamples() {
        let names = FirstLaunchLayout.sampleNames
        let paths = names.compactMap { name -> (String, URL)? in
            (sampleURLs == nil ? Self.sampleURL(name: name) : sampleURLs?[name]).map { (name, $0) }
        }
        // GCD rather than the cooperative pool: a busy pool must not hold back the Home's first paint.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var decoded: [String: CGImage] = [:]
            var failures = Set(names).subtracting(paths.map(\.0))
            for (name, url) in paths {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else {
                    failures.insert(name)
                    continue
                }
                decoded[name] = image
            }
            for name in failures {
                Logger(subsystem: "io.github.anzchy.mado", category: "B4Samples").error("Sample decode failed: \(name, privacy: .public)")
            }
            let images = decoded
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    for container in self.tiles {
                        let image = container.name.flatMap { images[$0] }
                        container.sublayers?.first?.contents = image
                        container.isHidden = image == nil
                    }
                    CATransaction.commit()
                    self.sampleLoadCompleted = true
                }
            }
        }
    }
}
