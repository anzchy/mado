import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func chromeFloatingGroupsFollowPanelMetricsInBothAppearances() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let overlay = ViewerChromeOverlay(frame: window.contentView!.bounds, session: ViewerSession(host: ChromeToolsHost()))
    window.contentView = overlay
    defer { window.close() }
    overlay.refresh(filename: "a.png")

    for (appearance, expected) in [(NSAppearance.Name.aqua, [255.0, 255.0, 255.0]),
                                   (.darkAqua, [20.0, 24.0, 33.0])] {
        window.appearance = NSAppearance(named: appearance)
        overlay.viewDidChangeEffectiveAppearance()
        for group in overlay.groups {
            #expect(group.layer?.cornerRadius == 6)
            let layerColor = try #require(group.layer?.backgroundColor)
            let color = try #require(NSColor(cgColor: layerColor)?.usingColorSpace(.deviceRGB))
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                .map { (Double($0) * 255).rounded() }
            #expect(rgb == expected)
        }
    }
    for (size, y) in [(NSSize(width: 1280, height: 800), 14.0), (NSSize(width: 800, height: 680), 14.0)] {
        let y = CGFloat(y)
        window.setContentSize(size)
        #expect(overlay.groups.map(\.frame.minY) == [y, y, y])
        #expect(overlay.groups.map(\.frame.height) == [38, 38, 38])
        // #444, page 14: leading pod 104 wide (侧栏/返回网格/更多), zoom pod 174 wide with the 100×26 缩放模式 select.
        #expect(overlay.groups[0].frame == NSRect(x: 16, y: y, width: 104, height: 38))
        #expect(overlay.groups[2].frame == NSRect(x: size.width - 190, y: y, width: 174, height: 38))
        for tool in overlay.tools where tool.command != .actualPixels {
            #expect(tool.frame.height == 28)
            #expect(tool.frame.minY == 5)
        }
        #expect(overlay.tools[6].frame == NSRect(x: 37, y: 6, width: 100, height: 26))
        #expect(overlay.tools[0].frame.minX == 5)
        #expect(overlay.tools[1].frame.minX == 37)
        #expect(overlay.tools[2].frame.minX == 69)
        #expect(overlay.tools[5].frame.minX == 5)
        #expect(overlay.tools[6].frame.minX == 37)
        #expect(overlay.tools[7].frame.minX == 139)
    }
}

@Test @MainActor func chromeNavigationMeasuresRealContentAndTruncatesAtCap() {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
        session: ViewerSession(host: ChromeToolsHost()))
    overlay.refresh(filename: "a.png")
    let shortWidth = overlay.groups[1].frame.width
    overlay.refresh(filename: "landscape-3x2.png")
    let mediumWidth = overlay.groups[1].frame.width
    overlay.refresh(filename: String(repeating: "long-filename-", count: 30) + ".png")
    let cappedWidth = overlay.groups[1].frame.width
    #expect(shortWidth < mediumWidth)
    #expect(mediumWidth < cappedWidth)
    #expect(cappedWidth == 260)
    overlay.refresh(filename: "a.png", position: "2 / 12")
    #expect(overlay.groups[1].frame.width > shortWidth)
    #expect(overlay.groups[1].frame.midX == overlay.bounds.midX)
}

@Test @MainActor func chromeResponsiveResizeKeepsEveryControlHitDistinct() throws {
    _ = NSApplication.shared
    let effects = ChromeToolsHost()
    let session = ViewerSession(host: effects)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let overlay = ViewerChromeOverlay(frame: window.contentView!.bounds, session: session)
    overlay.autoresizingMask = [.width, .height]; window.contentView = overlay
    defer { window.close() }
    overlay.refresh(filename: String(repeating: "long-filename-", count: 30) + ".png")
    // Include the reported 640pt failure and the 800×680 design minimum case.
    for width: CGFloat in [960, 640, 800, 610, 480, 334, 300, 238, 960] {
        window.setContentSize(NSSize(width: width, height: 680))
        for (index, group) in overlay.groups.enumerated() {
            #expect(overlay.bounds.contains(group.frame))
            for other in overlay.groups.dropFirst(index + 1) { #expect(!group.frame.intersects(other.frame)) }
        }
        for tool in overlay.tools where tool.acceptsFirstResponder {
            let centre = tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: overlay)
            #expect(overlay.hitTest(centre) === tool)
        }
    }
    ChromeTitlebarPolicy.apply(to: window, visible: true, fullScreen: false)
    #expect(window.contentMinSize == NSSize(width: 238, height: 168))
}
