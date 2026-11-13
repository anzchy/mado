import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

private final class Issue351PanelReference: NSView {
    var panel: PinnedDesign.Color!
    var contour: PinnedDesign.Color!
    var percent = 50.0
    var outerRadius = 6.0
    var inset = 2.0
    var innerRadius = 4.0
    var backingAlpha = 0.5
    var lineWidth = 0.5
    override func draw(_ dirtyRect: NSRect) {
        func color(_ value: PinnedDesign.Color, alpha: Double) -> NSColor {
            NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: alpha)
        }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: outerRadius - lineWidth / 2, yRadius: outerRadius - lineWidth / 2)
        color(panel, alpha: percent / 100).setFill(); outline.fill()
        color(panel, alpha: backingAlpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: innerRadius, yRadius: innerRadius).fill()
        color(contour, alpha: contour.alpha).setStroke()
        outline.lineWidth = lineWidth; outline.stroke()
    }
}

@MainActor private func issue351Background(_ group: NSView) throws -> NSView {
    try #require(group.subviews.first { $0.accessibilityIdentifier() == "chrome.tool-background" })
}

@MainActor private func issue351PanelPixels(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@MainActor private func issue351ColorMatches(_ actual: NSColor, _ expected: PinnedDesign.Color, alpha: Double) {
    let color = actual.usingColorSpace(.sRGB)!
    #expect(abs(color.redComponent - expected.red) < 0.025)
    #expect(abs(color.greenComponent - expected.green) < 0.025)
    #expect(abs(color.blueComponent - expected.blue) < 0.025)
    #expect(abs(color.alphaComponent - alpha) < 0.015)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue351FrostedPinnedPagesRenderPanelAndFixedBackingAtEveryTier() throws {
    _ = NSApplication.shared
    for page in ["viewer-controls", "viewer-inspector", "viewer-filmstrip"] {
        for theme in ["light", "dark"] {
            let design = try PinnedDesign.page(page, appearance: theme)
            let selector = ".prototype-shell .viewer-floating-controls > [data-viewer-controls]"
            #expect(try design.exactDeclaration(selector, "background") == "color-mix(in srgb, var(--color-panel) var(--tool-background-opacity), transparent)")
            #expect(try design.exactDeclaration(":root", "--tool-background-opacity") == "50%")
            let panel = try design.color(":root", "--color-panel", viewport: 1280)
            let backingSelector = ".viewer-floating-controls > [data-viewer-controls]::before"
            let inset = try design.length(backingSelector, "inset", viewport: 1280)
            let backingRadius = try design.length(backingSelector, "border-radius", viewport: 1280)
            let backing = try design.color(backingSelector, "background", viewport: 1280)
            #expect(inset == 2 && backingRadius == 4 && backing.alpha == 0.5)
            let radius = try design.length(".zoom-pod", "border-radius", viewport: 1280)
            let shadows = try design.boxShadowLayers(".zoom-pod", viewport: 1280)
            let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), session: ViewerSession())
            let window = NSWindow(contentRect: overlay.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = overlay
            defer { window.close() }
            overlay.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            overlay.viewDidChangeEffectiveAppearance()
            let visibleGroups = page == "viewer-filmstrip" ? [overlay.groups[0], overlay.groups[2]] : overlay.groups
            for percent in [30.0, 50, 100] {
                #expect(try design.exactDeclaration(":root[data-tool-opacity=\"\(Int(percent))\"]", "--tool-background-opacity") == "\(Int(percent))%")
                overlay.setToolBackgroundOpacity(percent)
                overlay.layoutSubtreeIfNeeded()
                for group in visibleGroups {
                    let surface = try issue351Background(group)
                    #expect(surface.frame == group.bounds)
                    let pixels = try issue351PanelPixels(surface)
                    // Clear of contour and control ink: outer edge then fixed inner backing.
                    issue351ColorMatches(try #require(pixels.colorAt(x: 1, y: 19)), panel, alpha: percent / 100)
                    issue351ColorMatches(try #require(pixels.colorAt(x: 3, y: 19)), panel,
                        alpha: 1 - (1 - percent / 100) * (1 - backing.alpha))
                    #expect(group.layer?.cornerRadius == CGFloat(radius))
                    #expect(group.layer?.shadowOpacity == Float(shadows[1].color.alpha))
                    #expect(group.layer?.shadowRadius == CGFloat(shadows[1].blur / 2))
                    #expect(group.layer?.shadowOffset.height == CGFloat(-shadows[1].y))
                    // #637 replaces the platform popover material with a visual-only sampled backdrop.
                    #expect(group.subviews.allSatisfy { !($0 is NSVisualEffectView) })
                    let backdrop = try #require(group.subviews.first { $0.accessibilityIdentifier() == "chrome.tool-blur" })
                    #expect(backdrop.isHidden == (percent == 100))
                    #expect(backdrop.frame == group.bounds)
                    let materialIndex = try #require(group.subviews.firstIndex(of: backdrop))
                    let surfaceIndex = try #require(group.subviews.firstIndex(of: surface))
                    #expect(materialIndex < surfaceIndex)
                    #expect(!backdrop.acceptsFirstResponder && !surface.acceptsFirstResponder)
                    #expect(backdrop.hitTest(NSPoint(x: 20, y: 20)) == nil)
                    #expect(surface.hitTest(NSPoint(x: 20, y: 20)) == nil)
                    // Composite the actual group with the platform material and foreground hidden:
                    // this observes any accidental opaque root underlay below the independent panel.
                    let visibility = group.subviews.map { ($0, $0.isHidden) }
                    for child in group.subviews where child !== surface { child.isHidden = true }
                    let shadowOpacity = group.layer?.shadowOpacity
                    group.layer?.shadowOpacity = 0
                    let groupPixels = try issue351PanelPixels(group)
                    if let shadowOpacity { group.layer?.shadowOpacity = shadowOpacity }
                    for (child, hidden) in visibility { child.isHidden = hidden }
                    issue351ColorMatches(try #require(groupPixels.colorAt(x: 1, y: 19)), panel, alpha: percent / 100)
                    let rootColor = try #require(group.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
                    #expect(rootColor.alphaComponent == (percent == 100 ? 1 : 0))
                    let reference = Issue351PanelReference(frame: surface.bounds)
                    reference.panel = panel; reference.contour = shadows[0].color; reference.percent = percent
                    reference.outerRadius = radius; reference.inset = inset; reference.innerRadius = backingRadius
                    reference.backingAlpha = backing.alpha; reference.lineWidth = shadows[0].spread
                    let expectedPixels = try issue351PanelPixels(reference)
                    var maximumAlphaDifference = 0.0
                    for y in 0..<pixels.pixelsHigh {
                        for x in 0..<pixels.pixelsWide {
                            let actualAlpha = try #require(pixels.colorAt(x: x, y: y)).alphaComponent
                            let expectedAlpha = try #require(expectedPixels.colorAt(x: x, y: y)).alphaComponent
                            maximumAlphaDifference = max(maximumAlphaDifference, abs(actualAlpha - expectedAlpha))
                        }
                    }
                    #expect(maximumAlphaDifference < 0.015, "Full rendered alpha contour, inset and rounded backing match pinned CSS")
                }
            }
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue351FrostedInitialPreferencesAndOpacityChangesPreserveTools() throws {
    _ = NSApplication.shared
    for initial in [30.0, 50, 100] {
        var value = DisplayPreferences(alwaysShowTools: true)
        value.toolBackgroundOpacity = initial
        let session = ViewerSession(preferencesStore: InMemoryDisplayPreferencesStore(value))
        let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 480, height: 240), session: session)
        overlay.appearance = NSAppearance(named: .aqua)
        overlay.viewDidChangeEffectiveAppearance()
        overlay.refresh(filename: "a.png", position: "1 / 3")
        let toolFrames = overlay.tools.map(\.frame)
        let groups = overlay.groups.map(\.frame)
        let labels = overlay.tools.map { $0.accessibilityLabel() }
        let roles = overlay.tools.map { $0.accessibilityRole() }
        let enabled = overlay.tools.map(\.acceptsFirstResponder)
        let surface = try issue351Background(overlay.groups[0])
        let initialPixels = try issue351PanelPixels(surface)
        #expect(abs(try #require(initialPixels.colorAt(x: 1, y: 19)).alphaComponent - initial / 100) < 0.015)
        for opacity in [100.0, 30, 50, initial] {
            overlay.setToolBackgroundOpacity(opacity)
            #expect(overlay.tools.map(\.frame) == toolFrames)
            #expect(overlay.groups.map(\.frame) == groups)
            #expect(overlay.tools.map { $0.accessibilityLabel() } == labels)
            #expect(overlay.tools.map { $0.accessibilityRole() } == roles)
            #expect(overlay.tools.map(\.acceptsFirstResponder) == enabled)
            for tool in overlay.tools {
                let pointInOverlay = overlay.convert(NSPoint(x: tool.frame.midX, y: tool.frame.midY), from: tool.superview)
                #expect(overlay.hitTest(pointInOverlay) === tool)
            }
        }
        #expect(try issue351PanelPixels(surface).tiffRepresentation == initialPixels.tiffRepresentation)
        overlay.setToolsVisible(false)
        #expect(overlay.groups.allSatisfy { $0.isHidden })
        #expect(overlay.tools.allSatisfy { !$0.acceptsFirstResponder })
        overlay.setToolsVisible(true)
        #expect(overlay.tools.map(\.acceptsFirstResponder) == enabled)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue351FrostedAppearanceAndInvalidOpacityRestoreDeterministically() throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 300), session: ViewerSession())
    let surface = try issue351Background(overlay.groups[0])
    var reference: Data?
    for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
        overlay.appearance = NSAppearance(named: appearance)
        overlay.viewDidChangeEffectiveAppearance()
        overlay.setToolBackgroundOpacity(50)
        let pixels = try issue351PanelPixels(surface)
        if appearance == .aqua {
            if let reference { #expect(pixels.tiffRepresentation == reference) }
            else { reference = pixels.tiffRepresentation }
        }
        for (input, alpha) in [(-100.0, 0.3), (101, 1), (Double.nan, 0.5), (.infinity, 0.5)] {
            overlay.setToolBackgroundOpacity(input)
            #expect(abs(try #require(issue351PanelPixels(surface).colorAt(x: 1, y: 19)).alphaComponent - alpha) < 0.015)
        }
    }
}
