import AppKit
import os

/// The menu bar icon shown while the Capture Bar is collapsed.
@MainActor protocol CaptureStatusItemHandle: AnyObject {
    func remove()
    func setHidden(_ hidden: Bool)
    var isOnScreen: Bool { get }
}

/// Collapse to the menu bar and restore (#685, grilling 2.2): the bar hides and a menu bar icon appears; clicking the
/// icon, or the show / collapse shortcut, brings the bar back. There is no menu-bar menu (capture-bar.html:19-20).
@MainActor final class CaptureBarCollapseController {
    typealias StatusItemFactory = @MainActor (_ toolTip: String, _ label: String, _ action: @escaping () -> Void)
        -> CaptureStatusItemHandle

    private let bar: NSWindow
    private let localize: (String) -> String
    private let makeStatusItem: StatusItemFactory
    private let changed: (Bool) -> Void
    private var item: CaptureStatusItemHandle?

    var isCollapsed: Bool { item != nil }

    init(bar: NSWindow, localize: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) },
         makeStatusItem: @escaping StatusItemFactory = SystemCaptureStatusItem.make,
         changed: @escaping (Bool) -> Void = { _ in }, iconPoll: Duration = .milliseconds(16),
         iconSettle: Duration = .milliseconds(300),
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         iconNeverLeft: @escaping @MainActor () -> Void = CaptureBarCollapseController.logIconNeverLeft) {
        self.bar = bar
        self.localize = localize
        self.makeStatusItem = makeStatusItem
        self.changed = changed
        self.iconPoll = iconPoll
        self.iconSettle = iconSettle
        self.sleep = sleep
        self.iconNeverLeft = iconNeverLeft
    }

    func collapse() {
        guard item == nil else { return }
        bar.orderOut(nil)
        // capture-bar.html:99: title 点按显示截图工具条, label Mado 截图：点按显示截图工具条.
        item = makeStatusItem(localize("Click to show the Capture Bar"),
                              localize("Mado Capture: click to show the Capture Bar")) { [weak self] in self?.restore() }
        if captures > 0 { item?.setHidden(true) }  // collapsed mid-Capture: keep it out of this image too
        changed(true)
    }

    func restore() {
        guard let item else { return }
        item.remove()
        self.item = nil
        bar.orderFrontRegardless()
        changed(false)
    }

    func toggle() {
        if isCollapsed { restore() } else { collapse() }
    }

    /// Captures in flight; the icon is hidden while at least one runs.
    private var captures = 0
    private let iconPoll: Duration
    private let iconSettle: Duration
    private let sleep: @MainActor (Duration) async -> Void
    private let iconNeverLeft: @MainActor () -> Void

    /// About one second at the default poll, plus the 300 ms settle: an icon that never reports gone does not hold the
    /// Capture forever.
    static let iconWaitPolls = 60

    /// One line, no paths: the icon's window was still listed when the wait ran out.
    static func logIconNeverLeft() {
        Logger(subsystem: "io.github.anzchy.mado.capture-helper", category: "capture")
            .notice("The menu bar icon was still listed after the wait; capturing after the settle delay.")
    }

    /// Runs one Capture with the collapsed bar's menu bar icon out of the image (#685 fix r2 F1). On macOS 26 the
    /// status item's window belongs to Control Center, so no filter on the helper's own windows can exclude it: the icon
    /// is hidden, the helper waits until the window server no longer lists it and then a settle delay for the fade-out
    /// (fix r4), the Capture runs, and the icon comes back on every exit path (saved, failed or cancelled). The collapsed
    /// state itself does not change; a Capture with the bar shown waits for nothing.
    ///
    /// Overlapping Captures (fix r5 F1): every caller awaits the same hide-and-settle, and the bodies run one at a
    /// time in arrival order, so a second Capture neither reads the fading icon nor overtakes the first and leaves it
    /// to fail as busy. The icon comes back once, after the last one ends.
    func whileCapturing<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        captures += 1
        if captures == 1, let item { iconGone = Task { await hideAndSettle(item) } }
        defer {
            captures -= 1
            if captures == 0 {
                iconGone = nil
                item?.setHidden(false)
            }
        }
        await takeTurn()
        defer { endTurn() }
        await iconGone?.value
        return try await body()
    }

    /// The hide-and-settle in flight, shared by every Capture until the last one ends.
    private var iconGone: Task<Void, Never>?
    /// Whether a Capture body holds the turn, and the callers waiting for it in arrival order.
    private var turnTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func takeTurn() async {
        guard turnTaken else { turnTaken = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty { turnTaken = false } else { waiting.removeFirst().resume() }
    }

    private func hideAndSettle(_ item: CaptureStatusItemHandle) async {
        item.setHidden(true)
        var polls = 0
        var listed = true
        while polls < Self.iconWaitPolls {
            listed = item.isOnScreen
            guard listed else { break }
            polls += 1
            await sleep(iconPoll)
        }
        if listed { iconNeverLeft() }
        // The compositor's fade-out can outlive the window list (fix r4, smoke685-20261115d 5.3).
        await sleep(iconSettle)
    }
}

/// An `NSStatusItem` with the capture glyph and no menu: a click restores the bar.
///
/// Hiding removes the item from the status bar and showing makes a new one, rather than `isVisible = false`, which
/// AppKit saves under the item's autosave name: a helper that quit mid-Capture would come back with no icon.
@MainActor final class SystemCaptureStatusItem: NSObject, CaptureStatusItemHandle {
    private var item: NSStatusItem?
    private let toolTip: String
    private let label: String
    private let action: () -> Void
    private var removed = false
    /// The window-server windows that drew the icon when it was hidden (on macOS 26 they belong to Control Center).
    private var hiddenWindowIDs: Set<CGWindowID> = []

    private init(toolTip: String, label: String, action: @escaping () -> Void) {
        self.toolTip = toolTip
        self.label = label
        self.action = action
        super.init()
        item = makeItem()
    }

    static func make(toolTip: String, label: String, action: @escaping () -> Void) -> CaptureStatusItemHandle {
        SystemCaptureStatusItem(toolTip: toolTip, label: label, action: action)
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: label)
            button.toolTip = toolTip
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier("capture.status-item")
            button.target = self
            button.action = #selector(clicked)
        }
        return item
    }

    @objc private func clicked() { action() }

    func remove() {
        removed = true
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            guard let item else { return }
            hiddenWindowIDs = Self.menuBarWindowIDs(drawing: item.button?.window)
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        } else {
            guard item == nil, !removed else { return }
            hiddenWindowIDs = []
            item = makeItem()
        }
    }

    /// Shown, or hidden but one of the windows that drew it is still on screen.
    var isOnScreen: Bool {
        guard item == nil else { return true }
        return !hiddenWindowIDs.isDisjoint(with: Self.onScreenWindows().map(\.id))
    }

    /// The item's own window, and any status-level window at the same place (macOS 26 draws the item in a Control
    /// Center window, "Item-0" at layer 25).
    private static func menuBarWindowIDs(drawing window: NSWindow?) -> Set<CGWindowID> {
        guard let window else { return [] }
        var ids: Set<CGWindowID> = []
        if let own = CGWindowID(exactly: window.windowNumber), own > 0 { ids.insert(own) }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.frame
        let bounds = CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        for candidate in onScreenWindows() {
            guard candidate.layer == statusLayer, candidate.bounds.insetBy(dx: -1, dy: -1).contains(bounds)
                    || bounds.insetBy(dx: -1, dy: -1).contains(candidate.bounds) else { continue }
            ids.insert(candidate.id)
        }
        return ids
    }

    private static func onScreenWindows() -> [(id: CGWindowID, layer: Int, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw) else { return nil }
            return (id, layer, bounds)
        }
    }
}
