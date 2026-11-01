import AppKit
import Testing
import PicseeApplication
@testable import PicseeMacUI

@MainActor private func issue114CoverageShell() -> (GridShellView, NSWindow) {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    // Off screen and not ordered in: key-view and appearance rules need a window, not a visible one.
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = shell
    shell.layoutSubtreeIfNeeded()
    return (shell, window)
}

@Test @MainActor func issue114PanelCoverageDecodingIsUnsupported() throws {
    #expect(GridDisplayPanelView(coder: NSKeyedArchiver(requiringSecureCoding: false)) == nil)
}

/// Page 15 controls take keyboard focus whenever the panel is shown (Tab cycles close → slider → names → fit),
/// independent of the system's full keyboard access setting, and refuse it once the panel is hidden or disabled.
@Test @MainActor func issue114PanelCoverageControlsFocusOnlyWhileShownAndEnabled() throws {
    let (shell, window) = issue114CoverageShell()
    let panel = shell.displayPanel
    let controls: [NSControl] = [panel.closeButton, panel.sizeSlider, panel.namesCheckbox, panel.fitPopup]
    shell.setDisplayPanelOpen(true)
    for control in controls {
        #expect(control.acceptsFirstResponder && control.canBecomeKeyView, "\(control)")
        #expect(window.makeFirstResponder(control))
        #expect(window.firstResponder === control)
    }
    #expect(panel.fitPopup.nextKeyView === panel.closeButton)
    panel.fitPopup.isEnabled = false
    #expect(!panel.fitPopup.acceptsFirstResponder && !panel.fitPopup.canBecomeKeyView)
    panel.fitPopup.isEnabled = true
    panel.isHidden = true
    for control in controls {
        #expect(!control.acceptsFirstResponder && !control.canBecomeKeyView, "\(control)")
    }
    panel.isHidden = false
    shell.setDisplayPanelOpen(false)
}

/// grid-display.html `--shadow-soft` / `--color-panel`: the panel follows the window between light and dark.
@Test @MainActor func issue114PanelCoverageAppearanceChangeRefreshesSurface() throws {
    let (shell, _) = issue114CoverageShell()
    let panel = shell.displayPanel
    shell.setDisplayPanelOpen(true)
    for (name, opacity) in [(NSAppearance.Name.darkAqua, Float(0.45)), (.aqua, Float(0.08))] {
        let appearance = try #require(NSAppearance(named: name))
        shell.appearance = appearance
        panel.viewDidChangeEffectiveAppearance()
        let layer = try #require(panel.layer)
        #expect(layer.shadowOpacity == opacity, "\(name)")
        var expected: CGColor?
        appearance.performAsCurrentDrawingAppearance { expected = DesignColor.popoverBackground.nsColor.cgColor }
        #expect(layer.backgroundColor == expected, "\(name)")
    }
}

/// Esc reaches the panel as `cancelOperation(_:)` from its controls' responder chain and closes it.
@Test @MainActor func issue114PanelCoverageCancelOperationCloses() throws {
    let (shell, window) = issue114CoverageShell()
    shell.setDisplayPanelOpen(true)
    #expect(shell.isDisplayPanelOpen)
    shell.displayPanel.cancelOperation(nil)
    #expect(!shell.isDisplayPanelOpen)
    #expect(window.firstResponder === shell.displayButton)
}

/// The store is the grid's one source: a grid that arrives with other options takes the stored ones on attach,
/// including the defaults.
@Test @MainActor func issue114PanelCoverageAttachedGridTakesStoredOptions() throws {
    _ = NSApplication.shared
    for stored in [GridDisplayOptions(), GridDisplayOptions(thumbnailSize: 260, showFileNames: false, fit: .fit)] {
        var preferences = DisplayPreferences()
        preferences.thumbnailSize = stored.thumbnailSize
        preferences.showFileNames = stored.showFileNames
        preferences.thumbnailFit = stored.fit
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  preferencesStore: InMemoryDisplayPreferencesStore(preferences))
        let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        grid.displayOptions = GridDisplayOptions(thumbnailSize: 140, showFileNames: stored.showFileNames == false,
                                                 fit: stored.fit == .fit ? .fill : .fit)
        shell.mainContent.addSubview(grid)
        shell.layoutSubtreeIfNeeded()
        #expect(grid.displayOptions == stored)
    }
}
