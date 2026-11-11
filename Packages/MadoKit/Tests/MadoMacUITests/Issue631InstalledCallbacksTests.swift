import AppKit
import SwiftUI
import Testing
@testable import MadoMacUI

@MainActor private func installed631<V: View>(_ view: V, size: NSSize = NSSize(width: 260, height: 80)) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor private func press631(_ window: NSWindow, at point: NSPoint) throws {
    let events: [(NSEvent.EventType, TimeInterval, Float)] = [(.leftMouseDown, 0, 1), (.leftMouseUp, 0.01, 0)]
    for (type, time, pressure) in events {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: pressure))
        window.sendEvent(event)
    }
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
}

@MainActor private func space631(_ window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                          isARepeat: false, keyCode: 49))
    window.sendEvent(event)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
}

@MainActor private func pressUntil631(_ window: NSWindow, xValues: [CGFloat], yValues: [CGFloat], calls: () -> Int) throws {
    let before = calls()
    for y in yValues {
        for x in xValues {
            try press631(window, at: NSPoint(x: x, y: y))
            if calls() != before { return }
        }
    }
    Issue.record("No installed button accepted a mouse press in the expected region")
}

@Test @MainActor func issue631InstalledButtonsRouteActionsAndKeyboard() throws {
    var iconCalls = 0
    let (iconWindow, _) = installed631(IconCommandButton(symbol: .sidebar, state: [], theme: .light) { iconCalls += 1 })
    defer { iconWindow.close() }
    try press631(iconWindow, at: NSPoint(x: 130, y: 40))
    #expect(iconCalls == 1)
    try space631(iconWindow)
    #expect(iconCalls == 2)

    var expand = 0, select = 0
    let (folderWindow, _) = installed631(FolderNavigationRow(nodeID: "a", name: "Folder", count: 3, expanded: false,
        state: [], theme: .light, onSelect: { select += 1 }, onExpand: { expand += 1 }))
    defer { folderWindow.close() }
    try press631(folderWindow, at: NSPoint(x: 12, y: 40))
    #expect(expand == 1)
    try space631(folderWindow)
    #expect(expand == 2)
    try pressUntil631(folderWindow, xValues: [250, 220, 190, 160, 130, 100, 70, 40],
                      yValues: [40, 25, 55, 10, 70], calls: { select })
    #expect(select == 1)
    try space631(folderWindow)
    #expect(select == 2)

    var thumb = 0
    let (thumbWindow, _) = installed631(ThumbnailSelectionFrame(filename: "a.png", state: [], theme: .light) { thumb += 1 })
    defer { thumbWindow.close() }
    try press631(thumbWindow, at: NSPoint(x: 130, y: 40))
    #expect(thumb == 1)

    var clear = 0
    let (searchWindow, _) = installed631(SearchFilterField(query: .constant("a"), resultCount: 1, state: [], theme: .light) { clear += 1 })
    defer { searchWindow.close() }
    try pressUntil631(searchWindow, xValues: [215, 190, 160, 130, 100, 70], yValues: [16, 30, 45, 60], calls: { clear })
    #expect(clear == 1)

    var scale = 0
    let (scaleWindow, _) = installed631(ScaleIndicator(actualPixels: false) { scale += 1 })
    defer { scaleWindow.close() }
    try press631(scaleWindow, at: NSPoint(x: 130, y: 40))
    #expect(scale == 1)

    var retry = 0
    let (errorWindow, _) = installed631(ImageErrorRow(message: "Error", state: []) { retry += 1 })
    defer { errorWindow.close() }
    try pressUntil631(errorWindow, xValues: Array(stride(from: CGFloat(10), through: CGFloat(250), by: CGFloat(10))),
                      yValues: Array(stride(from: CGFloat(10), through: CGFloat(70), by: CGFloat(10))), calls: { retry })
    #expect(retry == 1)
}

@MainActor private func pixels631(_ host: NSView) throws -> Data {
    host.layoutSubtreeIfNeeded()
    let size = host.bounds.size
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor private final class HoverHandlerBox631 {
    var handler: ((Bool) -> Void)?
}

@Test @MainActor func issue631InstalledSuppliedHoverClosureChangesVisibleSurface() throws {
    let iconBox = HoverHandlerBox631()
    var icon = IconCommandButton(symbol: .sidebar, state: [], theme: .light) {}
    icon.receiveHoverHandler = { iconBox.handler = $0 }
    let folderBox = HoverHandlerBox631()
    var folder = FolderNavigationRow(nodeID: "a", name: "Folder", count: 3, expanded: false,
                                     state: [], theme: .light, onSelect: {}, onExpand: {})
    folder.receiveHoverHandler = { folderBox.handler = $0 }
    let scaleBox = HoverHandlerBox631()
    var scale = ScaleIndicator(actualPixels: false) {}
    scale.receiveHoverHandler = { scaleBox.handler = $0 }
    let cases: [(AnyView, HoverHandlerBox631)] = [(AnyView(icon), iconBox), (AnyView(folder), folderBox), (AnyView(scale), scaleBox)]
    for (content, box) in cases {
        let (window, host) = installed631(content.environment(\.designReduceMotion, true))
        defer { window.close() }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        let handler = try #require(box.handler, "the supplied hover closure must be exposed on appear")
        let before = try pixels631(host)
        #expect(try pixels631(host).elementsEqual(before), "surface is stable before hover")
        handler(true)
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        let after = try pixels631(host)
        #expect(!after.elementsEqual(before), "the supplied hover closure must change the component surface")
        handler(false)
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        #expect(try pixels631(host).elementsEqual(before), "the supplied hover closure restores the surface on exit")
    }
}
