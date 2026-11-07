import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

/// Chromium's normal line boxes in the SHA-pinned SF Pro Text/Avenir stack:
/// 16pt h2=23, 13pt controls/name=19, 12pt metadata/recent heading=17.
/// These are pin measurements, not measurements of the native views under test.
private struct Issue518StackOracle {
    let iconTop: Double
    let headingTop: Double
    let middleTop: Double
    let middleHeight: Double
    let actionTop: Double
    let actionHeight: Double

    init(design: PinnedDesign, width: Double, height: Double, subfolders: Bool, grid: Bool) throws {
        let padding = try design.edges(".empty-state", "padding", viewport: width)
        let bottom = try design.length(".recovery-state", "padding-bottom", viewport: width)
        let outerTop = grid ? try design.length(".layout-exploration.is-grid .grid-scroll", "padding-top", viewport: width) : 0
        let footer = try design.length(".grid-bottom-bar", "height", viewport: width)
        let outerBottom = grid ? try design.length(".grid-scroll", "padding-bottom", viewport: width) - footer : 0
        let titleGap = try design.length(".empty-state h2", "margin-top", viewport: width)
        let detailGap = try design.length(".empty-state p", "margin-top", viewport: width)
        // Both pinned Chinese paragraphs fit one 460px line at these widths;
        // confirmed in i518-fix1-design.log, independently of native text layout.
        let detailHeight = try design.lineHeight(".empty-state p", viewport: width)
        let middleGap = try design.length(subfolders ? ".subfolder-tiles" : ".recent-folders", "margin-top", viewport: width)
        if subfolders {
            let tilePadding = try design.edges(".subfolder-tile", "padding", viewport: width)
            let tileGap = try design.length(".subfolder-tile", "gap", viewport: width)
            let border = try Self.border(design, ".subfolder-tile", width)
            // The pinned HTML's tile SVG is explicitly 16×16, with two flex gaps.
            middleHeight = 2 * border + tilePadding.top + 16 + 2 * tileGap + 19 + 17 + tilePadding.bottom
            let primary = try design.edges(".mock-primary", "padding", viewport: width)
            let text = try design.edges(".mock-actions .text-button", "padding", viewport: width)
            actionHeight = max(primary.top + 19 + primary.bottom, text.top + 19 + text.bottom)
        } else {
            let header = try design.edges(".recent-heading", "padding", viewport: width)
            let row = try design.edges(".recent-folder", "padding", viewport: width)
            middleHeight = 2 * (try Self.border(design, ".recent-folders", width))
                + header.top + 17 + header.bottom + (try Self.border(design, ".recent-heading", width, "border-bottom"))
                + 3 * (row.top + 19 + row.bottom) + 2 * (try Self.border(design, ".recent-folder+.recent-folder", width, "border-top"))
            let button = try design.edges(".secondary-button", "padding", viewport: width)
            actionHeight = button.top + 19 + button.bottom + 2 * (try Self.border(design, ".secondary-button", width))
        }
        let actionGap = try design.length(".mock-actions", "margin-top", viewport: width)
        let stackHeight = 32 + titleGap + 23 + detailGap + detailHeight + middleGap + middleHeight + actionGap + actionHeight
        iconTop = outerTop + padding.top + (height - outerTop - outerBottom - padding.top - bottom - stackHeight) / 2
        headingTop = iconTop + 32 + titleGap
        middleTop = headingTop + 23 + detailGap + detailHeight + middleGap
        actionTop = middleTop + middleHeight + actionGap
    }

    private static func border(_ design: PinnedDesign, _ selector: String, _ width: Double,
                               _ property: String = "border") throws -> Double {
        let raw = try design.raw(selector, property, viewport: width)
        return try design.lengthValue(String(raw.split(separator: " ")[0]), viewport: width)
    }
}

@MainActor private func issue518PositionShell(_ size: NSSize, _ appearance: NSAppearance.Name,
                                             subfolders: Bool) throws -> GridShellView {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/design/待整理")
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: size.width,
        height: size.height - (try issue518NativeTitlebarHeight())), preferencesStore: InMemoryDisplayPreferencesStore())
    shell.appearance = try #require(NSAppearance(named: appearance))
    let children = subfolders ? ["2024 冲绳", "手机备份", "扫描件"] : []
    shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil,
        children: children.map { GridSidebarFolder(url: folder.appendingPathComponent($0)) })
    let now = Date(timeIntervalSince1970: 1_615_809_600)
    let recents = [("日本 · 山海之间", 1), ("2024 家庭", 3), ("壁纸", 8)].map { name, days in
        RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/\(name)"), displayName: name,
            openedAt: now.addingTimeInterval(-Double(days) * 86_400))
    }
    shell.setEmptyFolderState(true, recents: recents, now: now)
    shell.layoutSubtreeIfNeeded()
    issue518UsePinnedText(shell.emptyFolderView, subfolders: subfolders)
    return shell
}

@MainActor private func issue518UsePinnedText(_ page: EmptyFolderStateView, subfolders: Bool) {
    // SwiftPM lacks the App's catalog; use the same deterministic Chinese text
    // as the pinned DOM so English wrapping cannot change the stack height.
    page.heading.stringValue = subfolders ? "这一层没有图片，但有 3 个子文件夹" : "这个文件夹还没有可浏览的图片"
    page.setDetailText(subfolders ? "打开一个子文件夹，把子文件夹里的图片一起显示，或把其他文件夹拖到这里。"
        : "换一个文件夹继续，或把文件夹拖到这里。")
    page.needsLayout = true
    page.layoutSubtreeIfNeeded()
    page.tiles.forEach { $0.layoutSubtreeIfNeeded() }
}

@MainActor private func issue518ExpectStack(_ page: EmptyFolderStateView, in container: NSView,
                                           oracle: Issue518StackOracle, subfolders: Bool, label: String) throws {
    func expect(_ view: NSView, top: Double, height: Double? = nil, name: String) {
        let frame = container.convert(view.bounds, from: view)
        let actual = Double(container.bounds.maxY - frame.maxY)
        #expect(abs(actual - top) <= 1, "\(label) \(name): top \(actual), CSS \(top)")
        if let height {
            #expect(abs(Double(frame.height) - height) <= 1, "\(label) \(name): height \(frame.height), CSS \(height)")
        }
    }
    expect(page.icon, top: oracle.iconTop, height: 32, name: "icon")
    expect(page.heading, top: oracle.headingTop, height: 23, name: "heading")
    if subfolders {
        #expect(page.tiles.count == 3 && page.recentRows.isEmpty)
        #expect(!page.primaryButton.isHidden && !page.chooseButton.isHidden)
        for (index, tile) in page.tiles.enumerated() {
            expect(tile, top: oracle.middleTop, height: oracle.middleHeight, name: "tile \(index)")
        }
        expect(page.primaryButton, top: oracle.actionTop, height: oracle.actionHeight, name: "包含子文件夹浏览")
    } else {
        #expect(page.tiles.isEmpty && page.recentRows.count == 3)
        expect(page.recentsGroup, top: oracle.middleTop, height: oracle.middleHeight, name: "recents")
    }
    expect(page.chooseButton, top: oracle.actionTop, height: oracle.actionHeight, name: "choose folder")
}

@Test @MainActor func issue518SubfolderRenderedTopsMatchPinnedCSS() throws {
    let design = try PinnedDesign.page("empty-folder")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)] {
            let shell = try issue518PositionShell(size, appearance, subfolders: true)
            if size.width == 1280 { #expect(shell.bounds.height == 772, "Real App content height below its 28pt titlebar") }
            let footer = try design.length(".grid-bottom-bar", "height", viewport: size.width)
            #expect(abs(shell.mainContent.bounds.height - (shell.bounds.height - footer)) < 0.01)
            let oracle = try Issue518StackOracle(design: design, width: size.width,
                height: shell.bounds.height - footer, subfolders: true, grid: true)
            try issue518ExpectStack(shell.emptyFolderView, in: shell.mainContent, oracle: oracle,
                subfolders: true, label: "grid \(appearance.rawValue) \(size.width)")
        }
    }
}

@Test @MainActor func issue518ViewerZeroInsetRenderedTopsMatchPinnedCSS() throws {
    let design = try PinnedDesign.page("empty-folder")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for subfolders in [true, false] {
            for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)] {
                let shell = try issue518PositionShell(size, appearance, subfolders: subfolders)
                let footer = try design.length(".grid-bottom-bar", "height", viewport: size.width)
                let host = ViewerStateHost(frame: NSRect(x: 0, y: 0, width: shell.mainContent.bounds.width,
                    height: shell.bounds.height - footer))
                host.appearance = try #require(NSAppearance(named: appearance))
                shell.mirrorEmptyFolderPage(to: host)
                host.display(.emptyFolder)
                host.layoutSubtreeIfNeeded()
                let page = host.emptyFolderView
                issue518UsePinnedText(page, subfolders: subfolders)
                #expect(page.frame == host.bounds, "Viewer owns the entire zero-inset surface")
                let oracle = try Issue518StackOracle(design: design, width: size.width,
                    height: host.bounds.height, subfolders: subfolders, grid: false)
                try issue518ExpectStack(page, in: host, oracle: oracle, subfolders: subfolders,
                    label: "viewer \(appearance.rawValue) \(size.width) \(subfolders ? "subfolders" : "recents")")
            }
        }
    }
}
