import AppKit
import Testing
import MadoApplication

// #685 helper side: Carbon hotkeys refuse a combo already held (AC-2 "taken by another app"), the bar's collapse
// button and tooltips (capture-bar.html:109-116), and collapse / restore through the menu bar icon (AC-3).

private let rare = CaptureKeyCombo(keyCode: 80, key: "F19", modifiers: [.control, .option, .command])

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CarbonHotKeyIsExclusiveAndReleasable() {
    let first = CarbonHotKeyRegistrar()
    let second = CarbonHotKeyRegistrar()
    defer { first.unregisterAll(); second.unregisterAll() }
    #expect(first.register(rare, id: 1))
    #expect(!second.register(rare, id: 1))
    first.unregister(id: 1)
    #expect(second.register(rare, id: 1))
    // Re-registering an id replaces its old combo.
    #expect(second.register(CaptureKeyCombo(keyCode: 79, key: "F18", modifiers: [.control, .option, .command]), id: 1))
    #expect(first.register(rare, id: 2))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CarbonModifierFlags() {
    #expect(CarbonHotKeyRegistrar.carbonModifiers([.control, .shift, .command]) == UInt32(controlKeyFlag | shiftKeyFlag | cmdKeyFlag))
    #expect(CarbonHotKeyRegistrar.carbonModifiers([.option]) == UInt32(optionKeyFlag))
    #expect(CarbonHotKeyRegistrar.carbonModifiers([]) == 0)
}

private let controlKeyFlag = 1 << 12, shiftKeyFlag = 1 << 9, cmdKeyFlag = 1 << 8, optionKeyFlag = 1 << 11

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CaptureBarCollapseButtonAndShortcutTooltips() throws {
    var collapsed = 0
    let shortcuts = Dictionary(uniqueKeysWithValues: [("capture.region", CaptureShortcutAction.region),
                                                      ("capture.window", .window), ("capture.screen", .fullScreen),
                                                      ("capture.text", .recognizeText)].map {
        ($0.0, CaptureShortcutBindings.defaults[$0.1]!.display)
    })
    let bar = CaptureBarView(localize: { $0 }, captureAction: {}, collapseAction: { collapsed += 1 }, shortcuts: shortcuts)
    func view(_ id: String) throws -> NSView { try #require(bar.subviews.first { $0.accessibilityIdentifier() == id }) }
    let collapse = try #require(try view("capture.collapse") as? NSButton)
    // capture-bar.html:73 .icon-only 32×32; :116 title 收起到菜单栏.
    #expect(collapse.isEnabled)
    #expect(abs(collapse.frame.width - 32) <= 1 && abs(collapse.frame.height - 32) <= 1)
    #expect(collapse.toolTip == "Collapse to Menu Bar")
    collapse.performClick(nil)
    #expect(collapsed == 1)
    // capture-bar.html:110-113 title "区域截图 ⌃⇧⌘1" … "截图并识别文字 ⌃⇧⌘4".
    #expect((try view("capture.region") as? NSButton)?.toolTip == "Region Capture ⌃⇧⌘1")
    #expect((try view("capture.window") as? NSButton)?.toolTip == "Window Capture ⌃⇧⌘2")
    #expect((try view("capture.screen") as? NSButton)?.toolTip == "Full Screen Capture ⌃⇧⌘3")
    #expect((try view("capture.text") as? NSButton)?.toolTip == "Capture and Recognize Text ⌃⇧⌘4")
    #expect((try view("capture.mado") as? NSButton)?.toolTip == "Open Mado")
    bar.setShortcuts(["capture.region": "⌃⌥F"])
    #expect((try view("capture.region") as? NSButton)?.toolTip == "Region Capture ⌃⌥F")
    #expect((try view("capture.window") as? NSButton)?.toolTip == "Window Capture")
    // capture-bar.html:109 the grip drags the bar: it is not a control, and the bar's background moves the window.
    let grip = try view("capture.grip")
    #expect(!(grip is NSButton))
    #expect(grip.mouseDownCanMoveWindow)
    #expect(bar.mouseDownCanMoveWindow)
    #expect(grip.toolTip == "Drag Capture Bar")
}

@MainActor private final class FakeStatusItem: CaptureStatusItemHandle {
    let toolTip: String
    let label: String
    let action: () -> Void
    var removed = false
    /// What happened to the icon, in order, shared with the Capture body (fix r2 F1).
    var log: (String) -> Void = { _ in }
    /// How many more reads report the icon still on screen after it was hidden.
    var lingeringReads = 0
    /// Called on the first read that reports the hidden icon gone (fix r4: the settle starts there).
    var gone: () -> Void = {}
    private var hidden = false
    init(_ toolTip: String, _ label: String, _ action: @escaping () -> Void) {
        self.toolTip = toolTip
        self.label = label
        self.action = action
    }
    func remove() { removed = true; log("remove") }
    func setHidden(_ hidden: Bool) { self.hidden = hidden; log(hidden ? "hide" : "show") }
    var isOnScreen: Bool {
        guard hidden else { return true }
        if lingeringReads > 0 { lingeringReads -= 1; log("still-on-screen"); return true }
        gone()
        gone = {}
        return false
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CollapseShowsOneMenuBarIconAndRestoreBringsTheBarBack() throws {
    let bar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
    defer { bar.orderOut(nil) }
    bar.orderFrontRegardless()
    var items: [FakeStatusItem] = []
    var changes: [Bool] = []
    let controller = CaptureBarCollapseController(bar: bar, localize: { $0 }, makeStatusItem: { tip, label, action in
        let item = FakeStatusItem(tip, label, action)
        items.append(item)
        return item
    }, changed: { changes.append($0) })
    #expect(!controller.isCollapsed)
    controller.collapse()
    controller.collapse()
    #expect(controller.isCollapsed)
    #expect(!bar.isVisible)
    try #require(items.count == 1)
    // capture-bar.html:99 title 点按显示截图工具条, aria-label Mado 截图：点按显示截图工具条.
    #expect(items[0].toolTip == "Click to show the Capture Bar")
    #expect(items[0].label == "Mado Capture: click to show the Capture Bar")
    items[0].action()  // clicking the icon
    #expect(!controller.isCollapsed)
    #expect(bar.isVisible)
    #expect(items[0].removed)
    controller.restore()
    controller.toggle()  // the show / collapse shortcut
    #expect(controller.isCollapsed && items.count == 2 && !bar.isVisible)
    controller.toggle()
    #expect(!controller.isCollapsed && bar.isVisible && items[1].removed)
    #expect(changes == [true, false, true, false])
}

// Fix r2 F1 (device smoke685 step 5): on macOS 26 the status item's window belongs to Control Center, so no filter on
// the helper's windows keeps the collapsed bar's icon out of a Capture. The icon is hidden, the helper waits until it
// is really gone, the Capture runs, and the icon comes back on every exit path. The collapsed state is unchanged.
private enum CaptureFailed: Error { case failed }

/// A virtual clock for the icon wait (fix r4): `sleep` advances `now` at once, so no test sleeps for real.
@MainActor private final class FakeCaptureClock {
    var now: Duration = .zero
    var sleeps: [Duration] = []
    /// When the fake window list first reported the icon gone.
    var goneAt: Duration?
    var neverLeftLogs = 0
    func sleep(_ duration: Duration) async {
        sleeps.append(duration)
        now += duration
    }
}

@MainActor private func collapsedController(_ log: @escaping (String) -> Void, lingering: Int = 0,
                                            clock: FakeCaptureClock = FakeCaptureClock())
    -> (CaptureBarCollapseController, () -> FakeStatusItem?) {
    let bar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
    var made: FakeStatusItem?
    let controller = CaptureBarCollapseController(bar: bar, localize: { $0 }, makeStatusItem: { tip, label, action in
        let item = FakeStatusItem(tip, label, action)
        item.log = log
        item.lingeringReads = lingering
        item.gone = { [weak clock] in clock?.goneAt = clock?.now }
        made = item
        return item
    }, iconPoll: .milliseconds(16), sleep: { await clock.sleep($0) }, iconNeverLeft: { clock.neverLeftLogs += 1 })
    return (controller, { made })
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CollapsedIconIsHiddenUntilGoneDuringACaptureAndComesBack() async throws {
    var log: [String] = []
    let (controller, item) = collapsedController({ log.append($0) }, lingering: 2)
    controller.collapse()
    try #require(item() != nil)
    let result = await controller.whileCapturing { log.append("capture"); return 7 }
    #expect(result == 7)
    #expect(log == ["hide", "still-on-screen", "still-on-screen", "capture", "show"])
    #expect(controller.isCollapsed)
    #expect(item()?.removed == false)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CollapsedIconComesBackWhenTheCaptureFailsOrIsCancelled() async throws {
    var log: [String] = []
    let (controller, _) = collapsedController({ log.append($0) })
    controller.collapse()
    await #expect(throws: CaptureFailed.self) {
        try await controller.whileCapturing { log.append("capture"); throw CaptureFailed.failed }
    }
    #expect(log == ["hide", "capture", "show"])
    log.removeAll()
    await #expect(throws: CancellationError.self) {
        try await controller.whileCapturing { log.append("capture"); throw CancellationError() }
    }
    #expect(log == ["hide", "capture", "show"])
    #expect(controller.isCollapsed)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CaptureWithTheBarShownTouchesNoIcon() async throws {
    var log: [String] = []
    let (controller, item) = collapsedController({ log.append($0) })
    await controller.whileCapturing { log.append("capture") }
    #expect(log == ["capture"])
    #expect(item() == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685IconThatNeverLeavesDoesNotHoldTheCaptureForever() async throws {
    var log: [String] = []
    let (controller, _) = collapsedController({ log.append($0) }, lingering: 10_000)
    controller.collapse()
    await controller.whileCapturing { log.append("capture") }
    #expect(log.first == "hide")
    #expect(log.suffix(2) == ["capture", "show"])
    #expect(log.filter { $0 == "still-on-screen" }.count <= CaptureBarCollapseController.iconWaitPolls)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685IconRestoredDuringACaptureStaysRemoved() async throws {
    var log: [String] = []
    let (controller, item) = collapsedController({ log.append($0) })
    controller.collapse()
    await controller.whileCapturing { log.append("capture"); controller.restore() }
    #expect(log == ["hide", "capture", "remove"])
    #expect(!controller.isCollapsed)
    #expect(item()?.removed == true)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685IconMadeDuringACaptureStartsHidden() async throws {
    var log: [String] = []
    let (controller, item) = collapsedController({ log.append($0) })
    await controller.whileCapturing { log.append("capture"); controller.collapse() }
    #expect(log == ["capture", "hide", "show"])
    #expect(controller.isCollapsed && item() != nil)
}

// Fix r4 (device smoke685-20261115d 5.3, 1 of 6): the window server stopped listing the icon's window while the
// compositor was still fading it out, so the first Capture after a collapse caught a faded icon. After the icon is no
// longer listed the helper waits a 300 ms settle before the screen read; a Capture with the bar shown waits for nothing.
@MainActor @Test(.timeLimit(.minutes(3))) func issue685ScreenReadWaitsTheSettleAfterTheIconLeavesTheList() async throws {
    var log: [String] = []
    let clock = FakeCaptureClock()
    let (controller, _) = collapsedController({ log.append($0) }, lingering: 2, clock: clock)
    controller.collapse()
    var readAt: Duration?
    await controller.whileCapturing { readAt = clock.now; log.append("capture") }
    let goneAt = try #require(clock.goneAt)
    let read = try #require(readAt)
    #expect(goneAt == .milliseconds(32))
    #expect(read >= goneAt + .milliseconds(300))
    #expect(read <= goneAt + .milliseconds(300) + .milliseconds(16))
    #expect(log == ["hide", "still-on-screen", "still-on-screen", "capture", "show"])
    #expect(clock.neverLeftLogs == 0)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685IconAlreadyGoneStillWaitsTheSettle() async throws {
    var log: [String] = []
    let clock = FakeCaptureClock()
    let (controller, _) = collapsedController({ log.append($0) }, clock: clock)
    controller.collapse()
    var readAt: Duration?
    await controller.whileCapturing { readAt = clock.now; log.append("capture") }
    #expect(clock.goneAt == .zero)
    #expect(try #require(readAt) >= .milliseconds(300))
    #expect(log == ["hide", "capture", "show"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685IconThatNeverLeavesStillWaitsTheSettleAndLogsOnce() async throws {
    var log: [String] = []
    let clock = FakeCaptureClock()
    let (controller, _) = collapsedController({ log.append($0) }, lingering: 10_000, clock: clock)
    controller.collapse()
    var readAt: Duration?
    await controller.whileCapturing { readAt = clock.now; log.append("capture") }
    let bound: Duration = .milliseconds(16) * CaptureBarCollapseController.iconWaitPolls
    let read = try #require(readAt)
    #expect(clock.goneAt == nil)
    #expect(read >= bound + .milliseconds(300))
    #expect(read <= .milliseconds(1_300))
    #expect(clock.neverLeftLogs == 1)
    #expect(log.suffix(2) == ["capture", "show"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CaptureWithTheBarShownGetsNoSettleDelay() async throws {
    var log: [String] = []
    let clock = FakeCaptureClock()
    let (controller, _) = collapsedController({ log.append($0) }, clock: clock)
    var readAt: Duration?
    await controller.whileCapturing { readAt = clock.now; log.append("capture") }
    #expect(readAt == .zero)
    #expect(clock.sleeps.isEmpty)
    #expect(log == ["capture"])
    controller.collapse()
    controller.restore()  // collapsed once, then shown again: still no delay
    await controller.whileCapturing { readAt = clock.now }
    #expect(readAt == .zero && clock.sleeps.isEmpty)
}
