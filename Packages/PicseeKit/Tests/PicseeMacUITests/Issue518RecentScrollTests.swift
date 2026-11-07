import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

private struct Issue518RecentOracle {
    let iconTop: CGFloat
    let headingTop: CGFloat
    let groupTop: CGFloat
    let groupHeight: CGFloat
    let actionTop: CGFloat

    init(_ pin: PinnedDesign, width: CGFloat, height: CGFloat, count: Int, grid: Bool) throws {
        let outerTop = grid ? try pin.length(".layout-exploration.is-grid .grid-scroll", "padding-top", viewport: width) : 0
        let outerBottom = grid ? try pin.length(".grid-scroll", "padding-bottom", viewport: width)
            - pin.length(".grid-bottom-bar", "height", viewport: width) : 0
        let padding = try pin.edges(".empty-state", "padding", viewport: width)
        let normal = [padding.top, try pin.length(".recovery-state", "padding-bottom", viewport: width),
            try pin.length(".empty-state h2", "margin-top", viewport: width),
            try pin.length(".empty-state p", "margin-top", viewport: width),
            count > 0 ? try pin.length(".recent-folders", "margin-top", viewport: width) : 0,
            try pin.length(".mock-actions", "margin-top", viewport: width)]
        let compact = try ["--compact-padding-top", "--compact-padding-bottom", "--compact-title-gap",
            "--compact-detail-gap", "--compact-recent-gap", "--compact-action-gap"].map {
                try pin.length(".recovery-state.has-recents", $0, viewport: width)
            }
        // Native rounds the pinned22.1pt paragraph box upward to prevent clipping.
        // Browser normal line boxes h2=23, action=19; button has7/7 padding+2border.
        let detail = ceil(try pin.lineHeight(".empty-state p", viewport: width))
        let fixed = 32.0 + 23 + detail + 35
        let naturalGroup = count == 0 ? 0 : 36 + 37 + Double(count - 1) * 38
        let available = Double(height) - outerTop - outerBottom
        let natural = fixed + normal.reduce(0, +) + naturalGroup
        let savings = zip(normal, compact).reduce(0) { $0 + $1.0 - $1.1 }
        let reduction = count == 0 ? 0 : min(1, max(0, natural - available) / savings)
        let spaces = zip(normal, compact).map { $0 - ($0 - $1) * reduction }
        let room = available - fixed - spaces.reduce(0, +)
        let group = count == 0 ? 0 : min(naturalGroup, max(0, room))
        let stack = fixed + spaces[2] + spaces[3] + spaces[4] + spaces[5] + group
        let top = outerTop + spaces[0] + max(0, (available - spaces[0] - spaces[1] - stack) / 2)
        iconTop = top
        headingTop = top + 32 + spaces[2]
        groupTop = top + 32 + spaces[2] + 23 + spaces[3] + detail + spaces[4]
        groupHeight = group
        actionTop = groupTop + group + spaces[5]
    }
}

@MainActor private final class Issue518RecentScene {
    let shell: GridShellView
    let host: ViewerStateHost?
    let page: EmptyFolderStateView
    let window: NSWindow
    let grid: Bool
    let pin: PinnedDesign

    init(count: Int, height: CGFloat, width: CGFloat, grid: Bool, appearance: NSAppearance.Name) throws {
        _ = NSApplication.shared
        self.grid = grid
        pin = try PinnedDesign.page("empty-folder")
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: height),
            preferencesStore: InMemoryDisplayPreferencesStore())
        shell.appearance = try #require(NSAppearance(named: appearance))
        let folder = URL(fileURLWithPath: "/design/待整理")
        shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil, children: [])
        let now = Date(timeIntervalSince1970: 1_615_809_600)
        let recents = (0..<count).map { index in
            RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/r\(index + 1)"),
                displayName: "最近文件夹 \(index + 1)", openedAt: now.addingTimeInterval(-Double(index + 1) * 86_400))
        }
        shell.setEmptyFolderState(true, recents: recents, now: now)
        shell.layoutSubtreeIfNeeded()
        if grid {
            host = nil
            page = shell.emptyFolderView
        } else {
            let viewer = ViewerStateHost(frame: NSRect(x: 0, y: 0, width: width, height: height))
            viewer.appearance = try #require(NSAppearance(named: appearance))
            shell.mirrorEmptyFolderPage(to: viewer)
            viewer.display(.emptyFolder)
            viewer.layoutSubtreeIfNeeded()
            host = viewer
            page = viewer.emptyFolderView
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = (host as NSView?) ?? shell
        page.heading.stringValue = "这个文件夹还没有可浏览的图片"
        page.setDetailText("换一个文件夹继续，或把文件夹拖到这里。")
        layout()
    }

    func layout() {
        (host as NSView? ?? shell).layoutSubtreeIfNeeded()
        page.needsLayout = true
        page.layoutSubtreeIfNeeded()
    }

    func checkGeometry(count: Int, label: String) throws {
        #expect(page.recentRows.count == count, "\(label): fixture count")
        let action = page.convert(page.chooseButton.bounds, from: page.chooseButton)
        #expect(!page.chooseButton.isHidden && page.bounds.insetBy(dx: -1, dy: -1).contains(action),
            "\(label): choose action fully inside visible page")
        if grid {
            let buttonInShell = shell.convert(page.chooseButton.bounds, from: page.chooseButton)
            #expect(buttonInShell.minY >= shell.footer.frame.maxY - 1, "\(label): action above footer")
        }
        let expected = try Issue518RecentOracle(pin, width: shell.bounds.width, height: page.bounds.height,
            count: count, grid: grid)
        func top(_ view: NSView) -> CGFloat { page.bounds.maxY - page.convert(view.bounds, from: view).maxY }
        #expect(abs(top(page.icon) - expected.iconTop) <= 1, "\(label): icon pin position")
        #expect(abs(top(page.heading) - expected.headingTop) <= 1, "\(label): heading pin position")
        #expect(abs(top(page.chooseButton) - expected.actionTop) <= 1, "\(label): action pin position")
        if count == 0 {
            #expect(page.recentsGroup.isHidden, "\(label): no empty recent scroll box")
            return
        }
        #expect(abs(top(page.recentsGroup) - expected.groupTop) <= 1, "\(label): group pin position")
        #expect(abs(page.recentsGroup.bounds.height - expected.groupHeight) <= 1, "\(label): pin list cap")
        let last = try #require(page.recentRows.last)
        let scroll = try #require(last.enclosingScrollView)
        let document = try #require(scroll.documentView)
        #expect(scroll.hasVerticalScroller, "\(label): system vertical scroller")
        #expect(!page.chooseButton.isDescendant(of: scroll), "\(label): action outside row scroller")
        var ancestor = scroll.superview
        while let view = ancestor {
            if let outer = view as? NSScrollView, let outerDocument = outer.documentView {
                #expect(outerDocument.bounds.height <= outer.contentSize.height + 1,
                    "\(label): no nested active vertical scroll range")
            }
            ancestor = view.superview
        }
        func rowVisible(_ row: NSView) -> Bool {
            scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(document.convert(row.bounds, from: row))
        }
        if page.bounds.height <= 640 {
            #expect(page.recentRows.filter { rowVisible($0) }.count >= min(count, 3),
                "\(label): at least three complete rows")
        }
        for row in page.recentRows {
            row.scrollToVisible(row.bounds)
            #expect(rowVisible(row), "\(label): each recent row scroll reachable")
            #expect(page.convert(page.chooseButton.bounds, from: page.chooseButton) == action,
                "\(label): row scrolling never moves action")
        }
        let topY = document.isFlipped ? document.bounds.minY : max(document.bounds.minY,
            document.bounds.maxY - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(window.makeFirstResponder(page.chooseButton))
        if document.bounds.height > scroll.contentSize.height + 1 {
            #expect(!rowVisible(last), "\(label): last row starts clipped before focus")
        }
        #expect(window.makeFirstResponder(last), "\(label): last row accepts real first responder")
        #expect(window.firstResponder === last && rowVisible(last), "\(label): focused last row revealed")
        if let first = page.recentRows.first {
            #expect(window.makeFirstResponder(first))
            #expect(window.firstResponder === first && rowVisible(first), "\(label): focus first reveals it again")
        }
        #expect(page.convert(page.chooseButton.bounds, from: page.chooseButton) == action,
            "\(label): focus reveal leaves action fixed")
    }
}

@Test @MainActor func issue518RecentScrollCountSizeThemeAndSurfaceMatrix() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for grid in [true, false] {
            for height: CGFloat in [640, 772] {
                for count in [0, 1, 5, 10] {
                    let scene = try Issue518RecentScene(count: count, height: height,
                        width: height == 640 ? 960 : 1280, grid: grid, appearance: appearance)
                    defer { scene.window.close() }
                    try scene.checkGeometry(count: count,
                        label: "\(appearance.rawValue) \(grid ? "grid" : "viewer") h\(height) rows\(count)")
                }
            }
        }
    }
}

@Test @MainActor func issue518RecentScrollExact640WindowSmoke() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let contentHeight = 640 - (try issue518NativeTitlebarHeight())
        #expect(contentHeight == 612, "960×640 window is distinct from640 content fixture")
        let scene = try Issue518RecentScene(count: 10, height: contentHeight, width: 960, grid: true, appearance: appearance)
        defer { scene.window.close() }
        try scene.checkGeometry(count: 10, label: "smoke640window \(appearance.rawValue)")
    }
}

@Test @MainActor func issue518RecentScrollFitAndResizeRestoration() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for grid in [true, false] {
            for count in [3, 10] {
                let scene = try Issue518RecentScene(count: count, height: 772, width: 1280, grid: grid, appearance: appearance)
                defer { scene.window.close() }
                let views: [NSView] = [scene.page.icon, scene.page.heading, scene.page.recentsGroup, scene.page.chooseButton]
                let frames = views.map { scene.page.convert($0.bounds, from: $0) }
                try scene.checkGeometry(count: count, label: "tall fit")
                for height: CGFloat in [640, 772] {
                    let container: NSView = (scene.host as NSView?) ?? scene.shell
                    container.frame.size.height = height
                    container.needsLayout = true
                    scene.layout()
                }
                #expect(views.map { scene.page.convert($0.bounds, from: $0) } == frames, "tall-compact-tall restores fit frames")
                scene.layout()
                #expect(views.map { scene.page.convert($0.bounds, from: $0) } == frames, "repeated fit layout is idempotent")
            }
        }
    }
}
