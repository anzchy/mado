import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

/// Page22 .drop-outline is positioned against recovery-scroll, independently
/// of the inset recovery-state stack. mainContent already excludes footer40.
@Test @MainActor func issue518StackInsetsPreserveFullDropArea() throws {
    _ = NSApplication.shared
    let pageDesign = try PinnedDesign.page("empty-folder")
    let inset = try pageDesign.length(".drop-outline", "inset", viewport: 1280)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 762),
                                  preferencesStore: InMemoryDisplayPreferencesStore())
        shell.wantsLayer = true
        let window = NSWindow(contentRect: shell.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = shell
        shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/design/待整理")),
                             parent: nil, children: [])
        shell.setEmptyFolderState(true, recents: [], now: Date(timeIntervalSince1970: 1_615_809_600))
        shell.layoutSubtreeIfNeeded()
        let page = shell.emptyFolderView
        page.layoutSubtreeIfNeeded()
        let expected = shell.convert(shell.mainContent.bounds.insetBy(dx: inset, dy: inset), from: shell.mainContent)
        let actual = shell.convert(page.dropOutline.bounds, from: page.dropOutline)
        #expect(actual == expected, "Drop outline retains the recovery-scroll's18pt inset, outside stack padding")
        // Render the native backing-layer tree so the portion of the real
        // outline below the inset page must survive ancestor clipping.
        shell.mainContent.wantsLayer = true
        page.dropOutline.isHidden = false
        page.dropOutline.layer?.backgroundColor = NSColor.magenta.cgColor
        shell.mainContent.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(shell.mainContent.bounds.width), pixelsHigh: Int(shell.mainContent.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)?.cgContext)
        try #require(shell.mainContent.layer).render(in: context)
        for y in [20, rep.pixelsHigh - 20] {
            let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1,
                    "Drop highlight is composited through the padding outside the page frame")
        }
        for y in [CGFloat(5), shell.mainContent.bounds.height - 5] {
            let point = shell.convert(NSPoint(x: shell.mainContent.bounds.midX, y: y), from: shell.mainContent)
            let hit = shell.hitTest(point)
            #expect(hit === page || hit?.isDescendant(of: page) == true,
                    "Empty-folder padding remains part of the folder drop destination")
        }
        for point in [NSPoint(x: 40, y: 60), NSPoint(x: 640, y: 20)] {
            let hit = shell.hitTest(point)
            #expect(hit !== page && hit?.isDescendant(of: page) != true, "Sidebar/footer are not drop padding")
        }
        page.dropOutline.isHidden = true
        let choosePoint = shell.convert(NSPoint(x: page.chooseButton.bounds.midX, y: page.chooseButton.bounds.midY),
                                        from: page.chooseButton)
        #expect(shell.hitTest(choosePoint) === page.chooseButton, "Content controls retain native mouse routing")
        page.isHidden = true
        let hiddenHit = shell.hitTest(shell.convert(NSPoint(x: shell.mainContent.bounds.midX, y: 5), from: shell.mainContent))
        #expect(hiddenHit !== page && hiddenHit?.isDescendant(of: page) != true, "Hidden empty page cannot receive drops")
    }
}
