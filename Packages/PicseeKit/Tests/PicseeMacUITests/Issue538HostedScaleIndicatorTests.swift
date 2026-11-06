import AppKit
import SwiftUI
import Testing
@testable import PicseeMacUI

@MainActor private func issue538Hosted<V: View>(_ content: V, theme: DesignTheme) -> (NSWindow, NSHostingView<some View>) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: content.frame(width: 122, height: 28)
        .background(DesignColor.popoverBackground.color)
        .environment(\.colorScheme, theme == .dark ? .dark : .light))
    host.frame = NSRect(x: 0, y: 0, width: 122, height: 28)
    let window = NSWindow(contentRect: host.frame.offsetBy(dx: -20000, dy: -20000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 122, height: 28))
    root.addSubview(host)
    // Keep the offscreen fixture from automatically focusing the sampled zoom control.
    let focusSink = NSTextField(frame: NSRect(x: -1000, y: -1000, width: 10, height: 10))
    root.addSubview(focusSink)
    window.contentView = root
    window.initialFirstResponder = focusSink
    window.orderFrontRegardless()
    window.makeFirstResponder(focusSink)
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@MainActor private func issue538CachedPixels(_ host: NSView) throws -> [Double] {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 122, pixelsHigh: 28,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = host.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    host.cacheDisplay(in: host.bounds, to: rep)
    var result: [Double] = []
    for y in 0..<28 {
        for x in 0..<122 {
            let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            result += [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
    }
    return result
}

@MainActor private func issue538Press(_ host: NSView, window: NSWindow) throws {
    let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
        modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 0))
    window.sendEvent(down)
    window.sendEvent(up)
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
}

/// The same independent single-opacity Text oracle as Issue538ScaleIndicatorOpacityTests,
/// now installed through NSHostingView and NSWindow rather than ImageRenderer alone.
@Test(arguments: [DesignTheme.light, .dark]) @MainActor
func issue538HostedDisabledLabelMatchesSingleOpacityAndRejectsActivation(_ theme: DesignTheme) throws {
    let reference = Text(String(localized: "Fit window"))
        .font(Font(DesignMetrics.font("uiSmall")))
        .foregroundStyle(DesignColor.textPrimary.color)
        .padding(5).frame(minWidth: 100).opacity(0.4)
    let (referenceWindow, referenceHost) = issue538Hosted(reference, theme: theme)
    defer { referenceWindow.close() }
    var actions = 0
    let disabled = ScaleIndicator(actualPixels: false, state: .disabled, theme: theme) { actions += 1 }
    let (disabledWindow, disabledHost) = issue538Hosted(disabled, theme: theme)
    defer { disabledWindow.close() }
    let expected = try issue538CachedPixels(referenceHost)
    let actual = try issue538CachedPixels(disabledHost)
    #expect(actual.count == expected.count)
    let maximumDelta = zip(actual, expected).map { abs($0 - $1) }.max() ?? 1
    // Require visible text, so a blank actual/reference pair cannot satisfy equality.
    let background = Array(expected.prefix(4))
    let referenceInk = stride(from: 0, to: expected.count, by: 4).filter { pixel in
        (0..<3).contains { abs(expected[pixel + $0] - background[$0]) > 0.03 }
    }.count
    #expect(referenceInk > 20)
    print("issue538 hosted \(theme): max cached channel delta \(maximumDelta), reference ink pixels \(referenceInk)")
    #expect(maximumDelta <= 2.0 / 255, "hosted disabled label matches independent 0.4 Text")
    try issue538Press(disabledHost, window: disabledWindow)
    #expect(actions == 0, "disabled installed button rejects real mouse activation")

    let enabled = ScaleIndicator(actualPixels: false, theme: theme) { actions += 1 }
    let (enabledWindow, enabledHost) = issue538Hosted(enabled, theme: theme)
    defer { enabledWindow.close() }
    try issue538Press(enabledHost, window: enabledWindow)
    #expect(actions == 1, "positive control: enabled installed button accepts the same mouse activation")
}
