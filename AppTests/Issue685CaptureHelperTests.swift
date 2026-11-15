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
    init(_ toolTip: String, _ label: String, _ action: @escaping () -> Void) {
        self.toolTip = toolTip
        self.label = label
        self.action = action
    }
    func remove() { removed = true }
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
