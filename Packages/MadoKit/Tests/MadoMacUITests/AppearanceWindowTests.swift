import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private func appearanceWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 320, height: 240),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@Test @MainActor func appearanceWindowAllValuesAndLateRegistration() {
    let store = InMemoryDisplayPreferencesStore()
    let adapter = WindowAppearanceAdapter(preferencesStore: store)
    let first = appearanceWindow(), second = appearanceWindow(), late = appearanceWindow()
    defer { first.close(); second.close(); late.close() }
    let inherited = first.effectiveAppearance.name
    adapter.register(first)
    adapter.register(second)
    let cases: [(DisplayAppearance, NSAppearance.Name?)] = [(.dark, .darkAqua), (.light, .aqua), (.system, nil), (.dark, .darkAqua)]
    for (preference, name) in cases {
        store.value.appearance = preference
        for window in [first, second] {
            #expect(window.appearance?.name == name)
            #expect(window.effectiveAppearance.name == (name ?? inherited))
        }
        adapter.register(late)
        adapter.register(late)
        #expect(late.appearance?.name == name)
        #expect(late.effectiveAppearance.name == (name ?? inherited))
    }
}

@Test @MainActor func appearanceWindowCloseReleaseAndReRegister() {
    let store = InMemoryDisplayPreferencesStore(DisplayPreferences(appearance: .dark))
    let adapter = WindowAppearanceAdapter(preferencesStore: store)
    let closed = appearanceWindow(), live = appearanceWindow()
    defer { closed.close(); live.close() }
    adapter.register(closed)
    adapter.register(live)
    #expect(closed.appearance?.name == .darkAqua)
    closed.close()
    store.value.appearance = .light
    #expect(closed.appearance?.name == .darkAqua)
    #expect(live.appearance?.name == .aqua)
    adapter.register(closed)
    #expect(closed.appearance?.name == .aqua)
    store.value.appearance = .system
    #expect(closed.appearance == nil)
    #expect(live.appearance == nil)
    weak var released: NSWindow?
    autoreleasepool {
        let temporary = appearanceWindow()
        released = temporary
        adapter.register(temporary)
    }
    #expect(released == nil)
    store.value.appearance = .dark
    #expect(live.appearance?.name == .darkAqua)
    #expect(closed.appearance?.name == .darkAqua)
}

@Test @MainActor func appearanceWindowPreservesImageZoomChromeAndFirstResponder() throws {
    let store = InMemoryDisplayPreferencesStore(DisplayPreferences(alwaysShowTools: true))
    let adapter = WindowAppearanceAdapter(preferencesStore: store)
    let session = ViewerSession(preferencesStore: store)
    let item = ItemID.ephemeral(UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
    session.beginBrowsing(items: [item], sourceVersion: .init(9), scrollAnchor: item)
    session.select(item)
    #expect(CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.preview, from: .key, to: session))
    let window = appearanceWindow()
    defer { window.close() }
    let content = NSView(frame: .init(x: 0, y: 0, width: 320, height: 240))
    let canvas = CanvasView(frame: content.bounds, session: session)
    content.addSubview(canvas)
    let field = NSTextField(string: "Keep editing")
    field.frame = .init(x: 0, y: 0, width: 150, height: 24)
    content.addSubview(field)
    window.contentView = content
    let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(.init(x: 0, y: 0, width: 40, height: 20))
    canvas.install(DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: .init(width: 40, height: 20)))
    canvas.magnify(by: log(2), at: .init(x: 160, y: 120))
    session.setInspectorVisible(true)
    #expect(window.makeFirstResponder(field))
    let responder = try #require(window.firstResponder)
    let generation = session.imageLoader.generation
    let zoom = session.zoomMode
    #expect(zoom == .custom(2))
    let selection = session.selection
    let preview = session.previewSet
    let locks = session.chrome.locks
    adapter.register(window)
    for preference: DisplayAppearance in [.dark, .light, .system] {
        store.value.appearance = preference
        #expect(canvas.hasImage)
        #expect(session.imageLoader.generation == generation)
        #expect(session.currentItemID == item)
        #expect(session.selection == selection)
        #expect(session.previewSet == preview)
        #expect(session.scrollAnchor == item)
        #expect(session.zoomMode == zoom)
        #expect(session.chrome.isPinned)
        #expect(session.chrome.locks == locks)
        #expect(session.inspectorFocus.isVisible)
        #expect(window.firstResponder === responder)
        #expect(field.stringValue == "Keep editing")
    }
}
