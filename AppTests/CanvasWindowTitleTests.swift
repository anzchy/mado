import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private final class StaticMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

@MainActor @Test func emptyRescanClearsAppWindowImageIdentity() throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: StaticMotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let imageURL = URL(fileURLWithPath: "/nested/only.png")
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 1, height: 1))

    controller.installImage(image, fileURL: imageURL)
    #expect(window.title == "only.png")
    #expect(window.representedURL == imageURL)

    controller.clearFolderImageForNoMatches()
    #expect(!controller.hasImage)
    #expect(controller.session.imageLoader.fileURL == nil)
    #expect(window.title == "Mado")
    #expect(window.representedURL == nil)

    controller.beginImageOpening()
    #expect(window.title == "Mado")
    #expect(window.representedURL == nil)
    controller.installImage(image, fileURL: imageURL)
    controller.imageLoadFailed(CancellationError())
    #expect(window.title == "Mado")
    #expect(window.representedURL == nil)
}

@MainActor @Test func issue136WindowRoutesInspectorCommandTabAndEscape() throws {
    let defaultsDomain = Bundle.main.bundleIdentifier ?? "PicseeAppTests"
    let keyboardMode = UserDefaults.standard.persistentDomain(forName: defaultsDomain)?["AppleKeyboardUIMode"]
    UserDefaults.standard.set(0, forKey: "AppleKeyboardUIMode")
    defer {
        if let keyboardMode { UserDefaults.standard.set(keyboardMode, forKey: "AppleKeyboardUIMode") }
        else { UserDefaults.standard.removeObject(forKey: "AppleKeyboardUIMode") }
    }
    _ = NSApplication.shared
    // design/prototypes/picsee-browser/states/viewer-inspector{,-light}.html:
    // the same right panel opens with Command-I, accepts Tab even with Keyboard Navigation off,
    // and returns focus to the canvas with Escape in viewer and Grid.
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: StaticMotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    let item = ItemID.rootRelative(rootID: AccessRootID(), relativePath: "current.png")
    controller.session.beginBrowsing(items: [item], sourceVersion: .init(1), scrollAnchor: item)
    controller.session.focus(item)
    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let content = try #require(window.contentView)
    let canvas = try #require(descendants(content)
        .first { $0.accessibilityIdentifier() == "viewer.canvas" })
    #expect(UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") == 0)
    for grid in [false, true] {
        if grid { controller.showGrid() }
        let entry: NSView = if grid {
            try #require(descendants(content).compactMap { $0 as? NSCollectionView }.first)
        } else { canvas }
        #expect(window.makeFirstResponder(entry))
        #expect(window.firstResponder === entry)
        controller.session.updateFocus(.canvas)
        try key(34, "i", modifiers: .command)
        #expect(controller.inspectorVisible)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let close = try #require(descendants(content)
            .compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "inspector.close" })
        #expect(close.acceptsFirstResponder) // AppKit override works with Keyboard Navigation off.
        for _ in 0..<12 where window.firstResponder !== close {
            try key(48, "\t")
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(window.firstResponder === close)
        #expect(controller.session.inspectorFocus.focus == .panel)
        try key(53, "\u{1b}")
        #expect(controller.session.inspectorFocus.focus == .canvas)
        #expect(window.firstResponder === entry)
        #expect(controller.inspectorVisible)
        try key(34, "i", modifiers: .command)
        #expect(!controller.inspectorVisible)
    }
}
