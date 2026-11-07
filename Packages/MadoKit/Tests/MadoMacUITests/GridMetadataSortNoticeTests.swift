import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func issue108GridMetadataSortNoticeIsAccessibleAndDoesNotReplaceGrid() {
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    #expect(grid.metadataSortNotice.isHidden)
    grid.setMetadataSortPending(true)
    grid.layoutSubtreeIfNeeded()
    #expect(!grid.metadataSortNotice.isHidden)
    #expect(grid.metadataSortNotice.accessibilityIdentifier() == "folder.sort.pending")
    #expect(grid.metadataSortNotice.accessibilityLabel() == String(localized: "Sort unfinished"))
    #expect(grid.bounds.maxX - grid.metadataSortNotice.frame.maxX == 20)
    #expect(grid.metadataSortNotice.frame.minY == 12)
    #expect(grid.metadataSortNotice.textColor == .secondaryLabelColor)
    #expect(grid.collectionView.superview != nil)
    #expect(grid.metadataSortNotice.hitTest(NSPoint(x: 1, y: 1)) == nil)
    for (appearance, theme) in [(NSAppearance.Name.aqua, DesignTheme.light), (.darkAqua, .dark)] {
        grid.appearance = NSAppearance(named: appearance)
        grid.viewDidChangeEffectiveAppearance()
        let actual = try? #require(grid.metadataSortNotice.layer?.backgroundColor?.components)
        #expect(actual?.count == 4)
        if let actual {
            for (component, expected) in zip(actual, DesignColor.canvasBackground.components(theme)) {
                #expect(abs(Double(component) - expected) < 0.01)
            }
        }
    }
    grid.setMetadataSortPending(false)
    #expect(grid.metadataSortNotice.isHidden)
}

@Test @MainActor func issue108SortStatusDistinguishesPendingAndUnavailableInBothSurfaces() {
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let viewer = ViewerChromeOverlay(frame: grid.frame, session: ViewerSession())
    for state in [MetadataSortState.pending, .incomplete] {
        grid.setMetadataSortState(state)
        viewer.setMetadataSortState(state)
        let expected = state == .pending ? String(localized: "Sort unfinished") : String(localized: "Sort metadata unavailable")
        #expect(grid.metadataSortNotice.stringValue == expected)
        #expect(viewer.metadataSortNotice.stringValue == expected)
        #expect(!grid.metadataSortNotice.isHidden && !viewer.metadataSortNotice.isHidden)
        #expect(viewer.metadataSortNotice.hitTest(.zero) == nil)
    }
    grid.setMetadataSortState(.complete)
    viewer.setMetadataSortState(.complete)
    #expect(grid.metadataSortNotice.isHidden && viewer.metadataSortNotice.isHidden)
}
