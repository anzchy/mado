import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private func issue406Scene() -> (GridShellView, NSWindow) {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let window = NSWindow(contentRect: shell.bounds, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    return (shell, window)
}

@MainActor private func issue406Hint(_ shell: GridShellView) throws -> (NSView, NSTextField, NSTextField) {
    let hint = try #require(shell.footer.subviews.first { $0.accessibilityIdentifier() == "grid.keyboard-hint" })
    let fields = hint.subviews.compactMap { $0 as? NSTextField }
    let keycap = try #require(fields.first { $0.stringValue == "Space" })
    let label = try #require(fields.first { $0 !== keycap })
    return (hint, keycap, label)
}

@MainActor private func issue406Color(_ actual: NSColor?, _ expected: PinnedDesign.Color,
                                     appearance: NSAppearance) throws {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance { resolved = actual?.usingColorSpace(.sRGB) }
    let color = try #require(resolved)
    #expect(abs(Double(color.redComponent) - expected.red) < 0.01)
    #expect(abs(Double(color.greenComponent) - expected.green) < 0.01)
    #expect(abs(Double(color.blueComponent) - expected.blue) < 0.01)
    #expect(abs(Double(color.alphaComponent) - expected.alpha) < 0.01)
}

@MainActor private func issue406Pressed(_ shell: GridShellView, design: PinnedDesign, on: Bool) throws {
    // grid-light/grid-dark .ds-icon-button[aria-pressed="true"] · color/background;
    // .ds-icon-button · color/background for the released state. The unrelated
    // .viewer-tools contextual rule is not applicable to the grid footer.
    let pressed = ".ds-icon-button[aria-pressed=\"true\"]"
    #expect(try design.exactDeclaration(pressed, "color") == "var(--color-text)")
    #expect(try design.exactDeclaration(pressed, "background") == "var(--color-hover)")
    let releasedColor = try design.exactDeclaration(".ds-icon-button", "color")
    try #require(releasedColor.hasPrefix("var(") && releasedColor.hasSuffix(")"))
    let releasedToken = String(releasedColor.dropFirst(4).dropLast())
    #expect(shell.toggleButton.state == (on ? .on : .off))
    #expect(shell.sidebar.isHidden == !on)
    try issue406Color(shell.toggleButton.contentTintColor,
        design.color(":root", on ? "--color-text" : releasedToken, viewport: 1280),
        appearance: shell.effectiveAppearance)
    let fill = shell.toggleButton.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
    if on {
        try issue406Color(fill, design.color(":root", "--color-hover", viewport: 1280),
            appearance: shell.effectiveAppearance)
    } else {
        #expect(try #require(fill).alphaComponent == 0)
    }
}

@MainActor private func issue406HintOutput(_ shell: GridShellView, design: PinnedDesign) throws {
    let (hint, keycap, label) = try issue406Hint(shell)
    #expect(!hint.isHidden)
    #expect(!label.stringValue.isEmpty)
    // .keyboard-hint>span · margin-right + .grid-bottom-bar · gap.
    let width = Double(shell.bounds.width)
    let expectedGap = try design.length(".keyboard-hint>span", "margin-right", viewport: width)
        + design.length(".grid-bottom-bar", "gap", viewport: width)
    // NSTextField draws its text 2pt inside its frame, as in the #281 status labels.
    let textBox = label.convert(label.bounds.insetBy(dx: 2, dy: 0), to: shell.footer)
    let searchFrame = shell.searchButton.convert(shell.searchButton.bounds, to: shell.footer)
    #expect(abs(Double(searchFrame.minX - textBox.maxX) - expectedGap) < 0.01)
    // Label inherits :root · --color-text; only .ds-keycap · color is muted.
    try issue406Color(label.textColor, design.color(":root", "--color-text", viewport: width),
        appearance: shell.effectiveAppearance)
    try issue406Color(keycap.textColor, design.color(".ds-keycap", "color", viewport: width),
        appearance: shell.effectiveAppearance)
    for field in [keycap, label] {
        #expect(field.frame.width >= ceil(try #require(field.cell).cellSize.width))
        #expect(hint.bounds.contains(field.frame))
    }
    #expect(keycap.frame.maxX <= label.frame.minX)
}

/// grid-light/grid-dark .ds-icon-button[aria-pressed="true"] · color/background.
@Test(.timeLimit(.minutes(2))) @MainActor func issue406PressedSidebarToggleFollowsPinnedColorsThroughRoundTrip() throws {
    for (page, name) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(page)
        let (shell, window) = issue406Scene()
        defer { window.close() }
        shell.appearance = try #require(NSAppearance(named: name))
        shell.viewDidChangeEffectiveAppearance()
        shell.layoutSubtreeIfNeeded()
        for (index, on) in [true, false, true].enumerated() {
            try issue406Pressed(shell, design: design, on: on)
            let frame = shell.toggleButton.frame
            shell.needsLayout = true
            shell.layoutSubtreeIfNeeded()
            #expect(shell.toggleButton.frame == frame, "Repeated layout preserves the toggle frame")
            if index < 2 { shell.toggleSidebar() }
        }
    }
}

/// grid-light/grid-dark .keyboard-hint>span · margin-right, .grid-bottom-bar · gap,
/// :root · --color-text, and .ds-keycap · color, with zh/en content-width fixtures.
@Test(.timeLimit(.minutes(2))) @MainActor func issue406HintColorsAndGapSurviveLocaleResizeAndSearchRoundTrips() throws {
    for (page, name) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(page)
        for text in ["Quick Look", "快速查看"] {
            let (shell, window) = issue406Scene()
            defer { window.close() }
            shell.appearance = try #require(NSAppearance(named: name))
            shell.viewDidChangeEffectiveAppearance()
            let (hint, _, label) = try issue406Hint(shell)
            label.stringValue = text // Content fixture; process locale selection belongs to App tests.
            var initial: NSRect?
            for width in [1280.0, 1060, 801, 800, 1280] {
                shell.setFrameSize(NSSize(width: width, height: 800))
                shell.needsLayout = true
                shell.layoutSubtreeIfNeeded()
                if width > 800 {
                    try issue406HintOutput(shell, design: design)
                    if initial == nil { initial = hint.frame }
                } else { #expect(hint.isHidden) }
            }
            #expect(hint.frame == initial, "Resize round-trip restores the original hint frame")
            shell.focusSearch()
            shell.layoutSubtreeIfNeeded()
            #expect(hint.isHidden)
            #expect(!shell.searchField.isHidden)
            shell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                object: shell.searchField))
            shell.layoutSubtreeIfNeeded()
            try issue406HintOutput(shell, design: design)
            #expect(hint.frame == initial, "Search round-trip restores the original hint frame")
        }
    }
}

/// grid-light/grid-dark pressed toggle · color/background, inherited hint · color,
/// .ds-keycap · color, and hint span margin-right + bottom-bar gap remain live.
@Test(.timeLimit(.minutes(2))) @MainActor func issue406ExistingShellRestylesAcrossAppearanceRoundTrip() throws {
    let (shell, window) = issue406Scene()
    defer { window.close() }
    let (hint, _, _) = try issue406Hint(shell)
    let original = hint.frame
    for (page, name) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua), ("grid-light", .aqua)] {
        shell.appearance = try #require(NSAppearance(named: name))
        shell.viewDidChangeEffectiveAppearance()
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
        let design = try PinnedDesign.page(page)
        try issue406Pressed(shell, design: design, on: true)
        try issue406HintOutput(shell, design: design)
        #expect(hint.frame == original)
    }
}
