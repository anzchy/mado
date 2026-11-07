import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

/// Read the App's current titlebar constant from its shell construction, so the
/// package fixture cannot silently normalize to the HTML's different titlebar.
func issue518NativeTitlebarHeight() throws -> CGFloat {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("App/CanvasWindowController.swift"), encoding: .utf8)
    let expression = try NSRegularExpression(pattern: #"height: content\.bounds\.height - ([0-9]+)\), preferencesStore: preferencesStore"#)
    let match = try #require(expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
    let range = try #require(Range(match.range(at: 1), in: source))
    return try #require(Double(source[range]))
}

/// #518 fix1: compare content coordinates below the native system titlebar.
/// CSS is evaluated at the same real shell height, not normalized to 800-38.
/// Normal browser line boxes: h2=23, recent header=17, row/button=19pt.
@Test @MainActor func issue518EmptyFolderRenderedTopsMatchPinnedCSS() throws {
    _ = NSApplication.shared
    let design = try PinnedDesign.page("empty-folder")
    let nativeTitlebar = try issue518NativeTitlebarHeight()
    #expect(nativeTitlebar == 28)
    let now = Date(timeIntervalSince1970: 1_615_809_600)
    let recents = [("日本 · 山海之间", 1), ("2024 家庭", 3), ("壁纸", 8)].map { name, days in
        RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/\(name)"),
                     displayName: name, openedAt: now.addingTimeInterval(-Double(days) * 86_400))
    }
    // All width media boundaries in the page, including rules which ultimately
    // only change horizontal layout. Check both sides and the boundary itself.
    let widths: [Double] = [1280] + [480, 600, 720, 800, 850, 1050, 1100, 1600].flatMap { [$0 - 1, $0, $0 + 1] }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800 - nativeTitlebar),
                                  preferencesStore: InMemoryDisplayPreferencesStore())
        shell.appearance = NSAppearance(named: appearance)
        shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/design/待整理")),
                             parent: nil, children: [])
        shell.setEmptyFolderState(true, recents: recents, now: now)
        var original: [NSRect]?
        for width in widths + [1280] {
            shell.frame.size = NSSize(width: width, height: 800 - nativeTitlebar)
            #expect(shell.bounds.height == 772)
            shell.needsLayout = true
            let page = shell.emptyFolderView
            // SwiftPM does not carry the App string catalog. Use the pin's zh-Hans
            // text so English wrapping cannot masquerade as a vertical offset.
            page.heading.stringValue = "这个文件夹还没有可浏览的图片"
            page.setDetailText("换一个文件夹继续，或把文件夹拖到这里。")
            shell.layoutSubtreeIfNeeded()
            page.needsLayout = true
            page.layoutSubtreeIfNeeded()
            #expect(page.recentRows.count == 3)
            #expect(page.tiles.isEmpty)
            let frames = [page.icon, page.heading, page.recentsGroup].map { shell.convert($0.bounds, from: $0) }
            if width == 1280 {
                if let original { #expect(frames == original, "Resize-return restores rendered frames") }
                else { original = frames }
            }
            page.needsLayout = true
            page.layoutSubtreeIfNeeded()
            #expect(frames == [page.icon, page.heading, page.recentsGroup].map { shell.convert($0.bounds, from: $0) },
                    "Repeated layout is idempotent")

            let outerTop = try design.length(".layout-exploration.is-grid .grid-scroll", "padding-top", viewport: width)
            let outerBottom = try design.length(".grid-scroll", "padding-bottom", viewport: width)
            let padding = try design.edges(".empty-state", "padding", viewport: width)
            let bottom = try design.length(".recovery-state", "padding-bottom", viewport: width)
            let titleGap = try design.length(".empty-state h2", "margin-top", viewport: width)
            let detailGap = try design.length(".empty-state p", "margin-top", viewport: width)
            let detailHeight = try design.lineHeight(".empty-state p", viewport: width)
            let recentGap = try design.length(".recent-folders", "margin-top", viewport: width)
            let actionGap = try design.length(".mock-actions", "margin-top", viewport: width)
            let recentPadding = try design.edges(".recent-heading", "padding", viewport: width)
            let rowPadding = try design.edges(".recent-folder", "padding", viewport: width)
            let actionPadding = try design.edges(".secondary-button", "padding", viewport: width)
            let recentHeight = 2 + recentPadding.top + 17 + recentPadding.bottom + 1
                + 3 * (rowPadding.top + 19 + rowPadding.bottom) + 2
            let actionHeight = actionPadding.top + 19 + actionPadding.bottom + 2
            let stackHeight = 32 + titleGap + 23 + detailGap + detailHeight
                + recentGap + recentHeight + actionGap + actionHeight
            let areaHeight = shell.bounds.height - outerTop - outerBottom
            let iconTop = outerTop + padding.top
                + (areaHeight - padding.top - bottom - stackHeight) / 2
            let headingTop = iconTop + 32 + titleGap
            let recentTop = headingTop + 23 + detailGap + detailHeight + recentGap
            for (name, view, expected) in [("icon", page.icon as NSView, iconTop),
                                           ("heading", page.heading as NSView, headingTop),
                                           ("recents", page.recentsGroup, recentTop)] {
                let frame = shell.convert(view.bounds, from: view)
                let actual = shell.bounds.height - frame.maxY
                #expect(abs(actual - expected) <= 1,
                        "\(appearance.rawValue) \(width) \(name): top \(actual), pinned CSS \(expected)")
            }
        }
        let page = shell.emptyFolderView
        let three = [page.icon, page.heading, page.recentsGroup].map { shell.convert($0.bounds, from: $0) }
        shell.setEmptyFolderState(true, recents: Array(recents.prefix(2)), now: now)
        page.heading.stringValue = "这个文件夹还没有可浏览的图片"
        page.setDetailText("换一个文件夹继续，或把文件夹拖到这里。")
        page.needsLayout = true; page.layoutSubtreeIfNeeded()
        #expect(page.recentRows.count == 2)
        let two = [page.icon, page.heading, page.recentsGroup].map { shell.convert($0.bounds, from: $0) }
        for index in three.indices {
            let shift = three[index].maxY - two[index].maxY
            // Added CSS row = 9 + 19 + 9 + 1 border = 38, half = 19.
            #expect(abs(shift - 19) <= 1, "One recent row changes centered stack top by half its height")
        }
        shell.setEmptyFolderState(true, recents: recents, now: now)
        page.heading.stringValue = "这个文件夹还没有可浏览的图片"
        page.setDetailText("换一个文件夹继续，或把文件夹拖到这里。")
        page.needsLayout = true; page.layoutSubtreeIfNeeded()
        #expect(three == [page.icon, page.heading, page.recentsGroup].map { shell.convert($0.bounds, from: $0) },
                "Restoring the third row restores the rendered stack")
    }
}
