import AppKit
import Testing
@testable import MadoMacUI

// PR #730 CI: NSCollectionViewFlowLayout.setItemSize: raises NSInternalInconsistencyException
// ("itemSize.width > 0 && itemSize.height > 0") and the process aborts. The grid sits hidden behind the viewer and
// keeps resizing with the window; a legacy scroller (no trackpad, or "Show scroll bars: Always") leaves its clip view
// under 2 × the 16 pt inset in a narrow window, and the geometry produced a zero-width item.

/// Every content width the grid can be given, down to none, yields an item size flow layout accepts.
@Test(.timeLimit(.minutes(2)), arguments: [CGFloat(0), 1, 16, 24, 31, 32, 33, 40])
func issue730GridGeometryItemSizeStaysPositiveInANarrowClipView(contentWidth: CGFloat) {
    let geometry = GridGeometry(viewportWidth: 238, contentWidth: contentWidth)
    #expect(geometry.itemSize.width > 0, "item width at content width \(contentWidth): \(geometry.itemSize)")
    #expect(geometry.itemSize.height > 0, "item height at content width \(contentWidth): \(geometry.itemSize)")
    #expect(geometry.columns == 1)
}

/// A grid laid out with a legacy scroller in a window narrower than its insets lays out without raising.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue730NarrowGridWithLegacyScrollerLaysOut() throws {
    _ = NSApplication.shared
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 238, height: 168))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 238, height: 168),
                          styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = grid
    let scrollView = try #require(grid.collectionView.enclosingScrollView)
    scrollView.scrollerStyle = .legacy
    for width: CGFloat in [238, 60, 40, 20, 0] {
        grid.setFrameSize(NSSize(width: width, height: 168))
        scrollView.tile()
        grid.layoutSubtreeIfNeeded()
        let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        #expect(layout.itemSize.width > 0 && layout.itemSize.height > 0, "grid \(width) pt: \(layout.itemSize)")
    }
}

/// Fix round r1 (opus L1): a content width just past the two insets still fits a positive item, so the item keeps that
/// computed width instead of growing to a floor wider than the room it has.
@Test(.timeLimit(.minutes(2)), arguments: [CGFloat(32.25), 32.5, 32.75, 33, 40])
func issue730GridGeometryKeepsAPositiveWidthThatFits(contentWidth: CGFloat) {
    let geometry = GridGeometry(viewportWidth: 238, contentWidth: contentWidth)
    let available = contentWidth - 2 * geometry.horizontalInset
    #expect(geometry.itemSize.width > 0, "item width at content width \(contentWidth): \(geometry.itemSize)")
    #expect(geometry.itemSize.width <= available, "item width at content width \(contentWidth): \(geometry.itemSize)")
    #expect(geometry.itemSize.width == available.nextDown, "item width at content width \(contentWidth): \(geometry.itemSize)")
}

/// Fix round r1 (opus L2): at a 40 pt grid only the legacy scroller takes the clip view under the two 16 pt insets;
/// with an overlay scroller the same grid keeps room for an item. Both lay out with a positive item size.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue730LegacyScrollerTakesTheClipViewUnderTheInsets() throws {
    _ = NSApplication.shared
    for style: NSScroller.Style in [.overlay, .legacy] {
        let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 238, height: 168))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 238, height: 168),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = grid
        let scrollView = try #require(grid.collectionView.enclosingScrollView)
        scrollView.scrollerStyle = style
        grid.setFrameSize(NSSize(width: 40, height: 168))
        scrollView.tile()
        grid.layoutSubtreeIfNeeded()
        let clipWidth = scrollView.contentView.frame.width
        if style == .legacy {
            #expect(clipWidth < 32, "legacy clip width \(clipWidth)")
        } else {
            #expect(clipWidth >= 32, "overlay clip width \(clipWidth)")
        }
        let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        #expect(layout.itemSize.width > 0 && layout.itemSize.height > 0, "\(style) clip \(clipWidth) pt: \(layout.itemSize)")
    }
}
