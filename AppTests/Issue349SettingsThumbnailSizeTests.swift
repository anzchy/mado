import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor @Test(.timeLimit(.minutes(3))) func issue349SettingsSliderLiveKeysAndKeyboardAX() throws {
    let store = InMemoryDisplayPreferencesStore(DisplayPreferences(alwaysShowTools: true, appearance: .dark))
    let a = try Issue349AppScene(store: store), b = try Issue349AppScene(store: store)
    let suite = "mado.settings349.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(directory: cacheURL),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: store), preferencesStore: store,
        defaults: defaults, updates: FakeUpdatePort())
    let previous = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {},
        openDiagnostics: {}, windowController: { a.controller })
    defer {
        NSApp.mainMenu = previous
        withExtendedLifetime(menu) {}
        panel.window.close(); a.close(); b.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: cacheURL)
    }
    panel.select(.display)
    panel.window.contentView?.layoutSubtreeIfNeeded()
    let slider = try #require(issue349Descendants(panel.window.contentView)
        .first { $0.accessibilityIdentifier() == "settings.display.size" } as? NSSlider)
    #expect(slider.isEnabled && slider.isContinuous)
    #expect(slider.accessibilityRole() == .slider)
    #expect(slider.isAccessibilityElement(), "the slider itself exposes its name and live value to AX")
    #expect(slider.accessibilityChildren()?.isEmpty != false, "one slider, without duplicate native wrapper elements")
    #expect((slider.accessibilityMinValue() as? NSNumber)?.doubleValue == 140)
    #expect((slider.accessibilityMaxValue() as? NSNumber)?.doubleValue == 280)
    #expect(slider.accessibilityLabel() == String(localized: "Thumbnail Size"))
    #expect(slider.acceptsFirstResponder && slider.canBecomeKeyView)
    #expect(slider.minValue == 140 && slider.maxValue == 280)
    var expected = store.value
    func expectSynchronized(_ size: Double) throws {
        expected.thumbnailSize = size
        #expect(store.value == expected)
        #expect(slider.doubleValue == size)
        #expect((slider.accessibilityValue() as? NSNumber)?.doubleValue == size)
        for scene in [a, b] {
            scene.settle()
            #expect(abs(try scene.tile().frame.height - 188.16 * size / 220) < 0.02)
        }
    }
    for size in [140.0, 170, 280] {
        slider.doubleValue = size
        #expect(slider.sendAction(slider.action, to: slider.target))
        try expectSynchronized(size)
    }
    for (key, expected) in [("-", 260.0), ("+", 280), ("0", 220)] {
        try a.key(key)
        try expectSynchronized(expected)
    }
    // Native key-view traversal must actually visit the slider, independent of full keyboard access.
    panel.window.recalculateKeyViewLoop()
    _ = panel.window.makeFirstResponder(panel.window)
    // An ordered-out test window has no initial view responder. Start native traversal from
    // a real view in its key loop, as AppKit does once a shown window establishes its first view.
    if let preceding = slider.previousKeyView { panel.window.selectKeyView(following: preceding) }
    var reached = false
    for _ in 0..<40 {
        panel.window.selectNextKeyView(nil)
        if panel.window.firstResponder === slider { reached = true; break }
    }
    #expect(reached, "Tab traversal reaches Thumbnail Size")
    panel.window.selectPreviousKeyView(nil)
    var reverseReached = false
    for _ in 0..<40 {
        panel.window.selectPreviousKeyView(nil)
        if panel.window.firstResponder === slider { reverseReached = true; break }
    }
    #expect(reverseReached, "Shift-Tab traversal reaches Thumbnail Size")
    #expect(panel.window.makeFirstResponder(slider))
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: panel.window.windowNumber, context: nil, characters: "\u{f703}",
        charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
    slider.keyDown(with: right)
    #expect(store.value.thumbnailSize > 220 && store.value.thumbnailSize <= 280)
    try expectSynchronized(store.value.thumbnailSize)
    let beforeAX = store.value.thumbnailSize
    #expect(slider.accessibilityPerformIncrement())
    try expectSynchronized(min(280, beforeAX + 10))
    #expect(slider.accessibilityPerformDecrement())
    try expectSynchronized(max(140, min(280, beforeAX + 10) - 10))
    panel.select(.general); panel.select(.display)
    #expect(slider.doubleValue == store.value.thumbnailSize)
    panel.select(.general)
    #expect(!slider.isAccessibilityElement() && !slider.canBecomeKeyView)
    let beforeHiddenAX = store.value
    #expect(!slider.accessibilityPerformIncrement())
    #expect(store.value == beforeHiddenAX)
    panel.select(.display)
    #expect(slider.isAccessibilityElement() && slider.canBecomeKeyView)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue349ViewerZoomKeepsThumbnailPreferenceAfterGridChange() throws {
    let store = InMemoryDisplayPreferencesStore()
    let scene = try Issue349AppScene(store: store)
    let viewer = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: store,
        accessServices: Task<AccessServices, Error> { throw CancellationError() },
        motionPolicy: MotionPolicy(source: Issue349Motion()))
    let viewerWindow = try #require(viewer.window)
    viewerWindow.orderOut(nil)
    let previous = NSApp.mainMenu
    var active = scene.controller
    let menu = CommandMenu(preferencesStore: store, openWithoutWindow: {}, openSettings: {},
        openDiagnostics: {}, windowController: { active })
    defer { NSApp.mainMenu = previous; withExtendedLifetime(menu) {}; scene.close(); viewerWindow.close() }
    try scene.key("-")
    #expect(store.value.thumbnailSize == 200)
    let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    viewer.installImage(DecodedImage(image: try #require(context.makeImage()),
        sourcePixelSize: CGSize(width: 800, height: 400)), fileURL: URL(fileURLWithPath: "/tmp/issue349/viewer.png"))
    let canvas = try #require(issue349Descendants(viewerWindow.contentView).compactMap { $0 as? CanvasView }.first)
    #expect(viewerWindow.makeFirstResponder(canvas))
    active = viewer
    func viewerKey(_ key: String) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: viewerWindow.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "0" ? 29 : key == "9" ? 25 : 24))
        #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: event))
    }
    for (key, mode) in [("0", ViewerZoomMode.actualPixels), ("9", .fit)] {
        try viewerKey(key)
        #expect(viewer.session.zoomMode == mode)
        #expect(store.value.thumbnailSize == 200)
    }
    try viewerKey("+"); try viewerKey("-")
    #expect(store.value.thumbnailSize == 200)
}
