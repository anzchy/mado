import AppKit
import SwiftUI
import Testing
@testable import PicseeMacUI

private struct Issue364PinnedScaleLabel: View {
    let label: String
    let hovered: Bool

    var body: some View {
        Button(action: {}) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textSecondary.color)
                .padding(5)
                .frame(minWidth: 68)
        }
        .buttonStyle(.plain)
        .background(hovered ? DesignColor.hoverBackground.color : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }
}

@MainActor private func issue364Pixels<V: View>(_ view: V, theme: DesignTheme) throws -> Data {
    let renderer = ImageRenderer(content: view
        .frame(width: 122, height: 28)
        .background(DesignColor.popoverBackground.color)
        .environment(\.colorScheme, theme == .dark ? .dark : .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    #expect(image.width == 122 && image.height == 28)
    return try #require(image.dataProvider?.data) as Data
}

@Test @MainActor func issue364ScaleLabelsMatchPinnedPlainAppearanceAndFit() throws {
    _ = NSApplication.shared
    let design = try PinnedDesign.page("viewer-controls")
    #expect(try design.exactDeclaration(".zoom-label", "background") == "transparent")
    #expect(try design.exactDeclaration(".zoom-label", "border") == "0")
    #expect(try design.length(".zoom-label", "padding", viewport: 1280) == 5)

    for theme in DesignTheme.allCases {
        for (actualPixels, customZoom) in [(false, nil), (true, nil), (false, 12.34)] {
            let scale = ScaleIndicator(actualPixels: actualPixels, customZoom: customZoom,
                                       theme: theme, input: .forced) {}
            for hovered in [false, true] {
                let state: ComponentState = hovered ? .hover : []
                let actual = ScaleIndicator(actualPixels: actualPixels, customZoom: customZoom,
                                            state: state, theme: theme, input: .forced) {}
                let reference = Issue364PinnedScaleLabel(label: scale.label, hovered: hovered)
                #expect(try issue364Pixels(actual, theme: theme) == issue364Pixels(reference, theme: theme),
                        "page 14 .zoom-label \(scale.label), hovered=\(hovered), theme=\(theme)")
            }

            let actualHost = NSHostingView(rootView: scale)
            let referenceHost = NSHostingView(rootView: Issue364PinnedScaleLabel(label: scale.label, hovered: false))
            actualHost.layoutSubtreeIfNeeded()
            referenceHost.layoutSubtreeIfNeeded()
            #expect(referenceHost.fittingSize.width >= 68)
            #expect(abs(actualHost.fittingSize.width - referenceHost.fittingSize.width) < 0.01,
                    "min-width 68 and unpadded text must fit \(scale.label)")
        }

        let rest = ScaleIndicator(actualPixels: false, theme: theme, input: .forced) {}
        let focused = ScaleIndicator(actualPixels: false, state: .keyboardFocused,
                                     theme: theme, input: .forced) {}
        #expect(try issue364Pixels(rest, theme: theme) != issue364Pixels(focused, theme: theme),
                "keyboard focus keeps its visible ring")
    }
}

@MainActor private func issue364InstalledPixel(_ host: NSView, x: Int, y: Int) throws -> NSColor {
    host.layoutSubtreeIfNeeded()
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width),
        pixelsHigh: Int(host.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = host.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    host.cacheDisplay(in: host.bounds, to: rep)
    let color = try #require(rep.colorAt(x: x, y: y))
    return try #require(color.usingColorSpace(.sRGB))
}

@MainActor private func issue364ReferencePixel(hovered: Bool, theme: DesignTheme) throws -> NSColor {
    let scale = ScaleIndicator(actualPixels: false, state: hovered ? .hover : [],
                               theme: theme, input: .forced) {}
    let renderer = ImageRenderer(content: scale
        .frame(width: 122, height: 28)
        .background(DesignColor.popoverBackground.color)
        .environment(\.colorScheme, theme == .dark ? .dark : .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    let rep = NSBitmapImageRep(cgImage: image)
    let color = try #require(rep.colorAt(x: 2, y: 14))
    return try #require(color.usingColorSpace(.sRGB))
}

@Test @MainActor func issue364InstalledScaleIndicatorRendersRealHoverEvents() throws {
    _ = NSApplication.shared
    for theme in DesignTheme.allCases {
        let scale = ScaleIndicator(actualPixels: false, theme: theme) {}
        let host = NSHostingView(rootView: scale)
        host.frame = NSRect(x: 0, y: 0, width: 122, height: 28)
        host.wantsLayer = true
        let appearance = try #require(NSAppearance(named: theme == .dark ? .darkAqua : .aqua))
        host.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            host.layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
        }
        let window = NSWindow(contentRect: host.frame.offsetBy(dx: -20000, dy: -20000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        for view in views { view.updateTrackingAreas() }
        let owners = views.filter { view in
            view.trackingAreas.contains { area in
                (area.owner as AnyObject?) === view && area.options.contains(.mouseEnteredAndExited)
            }
        }
        #expect(!owners.isEmpty)
        let rest = try issue364InstalledPixel(host, x: 2, y: 14)

        let location = host.convert(CGPoint(x: 61, y: 14), to: nil)
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil))
        for owner in owners { owner.mouseEntered(with: entered) }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        let hover = try issue364InstalledPixel(host, x: 2, y: 14)

        let exitedEvent = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: location,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, trackingNumber: 0, userData: nil))
        for owner in owners { owner.mouseExited(with: exitedEvent) }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        let exited = try issue364InstalledPixel(host, x: 2, y: 14)

        let expectedRest = try issue364ReferencePixel(hovered: false, theme: theme)
        let expectedHover = try issue364ReferencePixel(hovered: true, theme: theme)
        let actualDelta = [hover.redComponent - rest.redComponent,
                           hover.greenComponent - rest.greenComponent,
                           hover.blueComponent - rest.blueComponent]
        let expectedDelta = [expectedHover.redComponent - expectedRest.redComponent,
                             expectedHover.greenComponent - expectedRest.greenComponent,
                             expectedHover.blueComponent - expectedRest.blueComponent]
        for channel in 0..<3 {
            #expect(abs(actualDelta[channel] - expectedDelta[channel]) < 0.02,
                    "real mouseEntered fill channel \(channel), theme=\(theme)")
        }
        for channel in 0..<3 {
            let actual = [exited.redComponent, exited.greenComponent, exited.blueComponent][channel]
            let initial = [rest.redComponent, rest.greenComponent, rest.blueComponent][channel]
            #expect(abs(actual - initial) < 0.02, "real mouseExited restores channel \(channel), theme=\(theme)")
        }
    }
}
