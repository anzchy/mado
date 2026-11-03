import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@MainActor func issue219Menu() -> NSMenu {
    let main = NSMenu(title: "Picsee")
    func submenu(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return menu
    }
    func add(_ title: String, _ key: String, _ action: String, to menu: NSMenu,
             modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
    }
    let app = submenu("Picsee")
    add("Settings…", ",", "showSettings:", to: app)
    add("Hide Picsee", "h", "hide:", to: app)
    add("Hide Others", "h", "hideOtherApplications:", to: app, modifiers: [.option, .command])
    add("Quit Picsee", "q", "terminate:", to: app)
    let file = submenu("File")
    add("Open…", "o", "invoke:", to: file)
    add("Close", "w", "performClose:", to: file)
    let edit = submenu("Edit")
    add("Undo", "z", "undo:", to: edit)
    add("Redo", "z", "redo:", to: edit, modifiers: [.command, .shift])
    let view = submenu("View")
    add("Search current folder", "f", "focusGridSearch:", to: view)
    add("Hide sidebar", "s", "toggleSidebar:", to: view, modifiers: [.control, .command])
    add("Enter Full Screen", "f", "toggleFullScreen:", to: view, modifiers: [.control, .command])
    let window = submenu("Window")
    add("Minimize", "m", "performMiniaturize:", to: window)
    return main
}

let issue219ExpectedRows: [(String, [String], [String], [String], [String])] = [
    ("files", ["command:open"], ["⌘", "O"], ["Open…"], ["打开…"]),
    ("files", ["menu:Settings…"], ["⌘", ","], ["Settings…"], ["设置…"]),
    ("files", ["menu:Close"], ["⌘", "W"], ["Close Window"], ["关闭窗口"]),
    ("files", ["menu:Minimize"], ["⌘", "M"], ["Minimize"], ["最小化"]),
    ("files", ["menu:Hide Picsee"], ["⌘", "H"], ["Hide picsee"], ["隐藏 picsee"]),
    ("files", ["menu:Hide Others"], ["⌥", "⌘", "H"], ["Hide Others"], ["隐藏其他"]),
    ("files", ["menu:Quit Picsee"], ["⌘", "Q"], ["Quit picsee"], ["退出 picsee"]),
    ("grid", ["key:grid-arrows"], ["←", "→", "↑", "↓"], ["Move Current"], ["移动当前项"]),
    ("grid", ["command:preview"], ["Space"], ["Preview Current Item"], ["用大图查看当前项"]),
    ("grid", ["command:enter"], ["Return"], ["Open Current Item"], ["打开当前项"]),
    ("grid", ["menu:Search current folder"], ["⌘", "F"], ["Search Current Folder"], ["搜索当前文件夹"]),
    ("grid", ["menu:Hide sidebar"], ["⌃", "⌘", "S"], ["Show / Hide Sidebar"], ["显示 / 隐藏侧栏"]),
    ("viewer", ["command:previous", "command:next"], ["←", "→"], ["Previous / Next Image"], ["上一张 / 下一张"]),
    ("viewer", ["command:escape"], ["Esc"], ["Return to Grid"], ["回到网格"]),
    ("viewer", ["command:fit"], ["0"], ["Fit Window"], ["适应窗口"]),
    ("viewer", ["command:actualPixels"], ["1"], ["Actual Pixels"], ["实际像素"]),
    ("viewer", ["command:zoomIn", "command:zoomOut"], ["+", "−"], ["Zoom In / Out"], ["放大 / 缩小"]),
    ("viewer", ["key:viewer-tab"], ["Tab"], ["Recall Tools"], ["唤回工具"]),
    ("viewer", ["command:inspector"], ["⌘", "I"], ["Image Information"], ["图片信息"]),
    ("viewer", ["menu:Enter Full Screen"], ["⌃", "⌘", "F"], ["Toggle Full Screen"], ["进入 / 退出全屏"]),
]

@MainActor private func issue219Flatten(_ catalog: ShortcutCatalog) -> [(String, [String], [String], String)] {
    catalog.cards.flatMap { card in
        card.rows.map { (card.id.rawValue, $0.sources.map(\.id), $0.keycaps, $0.name) }
    }
}

@Test @MainActor func issue219ShortcutCatalogMatchesLiveSourcesAndKeycaps() throws {
    let catalog = ShortcutCatalog(menu: issue219Menu(), language: .english)
    let actual = issue219Flatten(catalog)
    #expect(actual.count == issue219ExpectedRows.count)
    for (row, expected) in zip(actual, issue219ExpectedRows) {
        #expect(row.0 == expected.0)
        #expect(row.1 == expected.1)
        #expect(row.2 == expected.2)
        #expect(row.3 == expected.3[0])
    }
    #expect(catalog.cards.map(\.title) == ["Files & Windows", "Grid", "Image Viewer"])
    #expect(catalog.cards.map(\.when) == ["Anytime", "While Browsing a Folder", "While Viewing One Image"])
}

@Test @MainActor func issue219ShortcutCatalogUsesSimplifiedChinese() {
    let catalog = ShortcutCatalog(menu: issue219Menu(), language: .simplifiedChinese)
    let actual = issue219Flatten(catalog)
    #expect(actual.count == issue219ExpectedRows.count)
    for (row, expected) in zip(actual, issue219ExpectedRows) {
        #expect(row.3 == expected.4[0])
    }
    #expect(catalog.cards.map(\.title) == ["文件与窗口", "网格", "大图"])
    #expect(catalog.cards.map(\.when) == ["任何时候", "浏览文件夹时", "查看一张图片时"])
}

@Test @MainActor func issue219ShortcutCatalogFollowsImplementedFlagAndMenuAvailability() throws {
    let menu = issue219Menu()
    let settings = try #require(menu.items.first { $0.title == "Picsee" }?.submenu?.items.first { $0.title == "Settings…" })
    settings.keyEquivalent = ""
    let catalog = ShortcutCatalog(menu: menu, implementedCommands: Set(CommandID.allCases).subtracting([.fit, .inspector]), language: .english)
    let sources = issue219Flatten(catalog).flatMap(\.1)
    #expect(!sources.contains("command:fit"))
    #expect(!sources.contains("command:inspector"))
    #expect(!sources.contains("menu:Settings…"))
    #expect(sources.contains("command:open"))
    #expect(sources.contains("menu:Search current folder"))
    #expect(sources.filter { $0 == "command:open" }.count == 1)
    #expect(sources.contains("menu:Undo") == false)
    #expect(sources.contains("menu:Redo") == false)
}

@Test @MainActor func issue219ShortcutCatalogKeepsAllRowsWithChineseMenuTitles() {
    let menu = issue219Menu()
    let titles = [
        "Settings…": "设置…", "Hide Picsee": "隐藏 Picsee", "Hide Others": "隐藏其他",
        "Quit Picsee": "退出 Picsee", "Open…": "打开…", "Close": "关闭",
        "Search current folder": "搜索当前文件夹", "Hide sidebar": "隐藏侧栏",
        "Enter Full Screen": "进入全屏", "Minimize": "最小化",
    ]
    for item in menu.items {
        for menuItem in item.submenu?.items ?? [] {
            if let title = titles[menuItem.title] { menuItem.title = title }
        }
    }
    let catalog = ShortcutCatalog(menu: menu, language: .simplifiedChinese)
    let actual = issue219Flatten(catalog)
    #expect(actual.count == 20)
    for (row, expected) in zip(actual, issue219ExpectedRows) {
        #expect(row.1 == expected.1)
        #expect(row.2 == expected.2)
        #expect(row.3 == expected.4[0])
    }
}

@Test @MainActor func issue219ShortcutCatalogKeepsRowsWhenMenuActionsAreRetitled() throws {
    let menu = issue219Menu()
    let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
    try #require(view.items.first { $0.title == "Hide sidebar" }).title = "Show sidebar"
    try #require(view.items.first { $0.title == "Enter Full Screen" }).title = "Exit Full Screen"
    let catalog = ShortcutCatalog(menu: menu, language: .english)
    let sources = issue219Flatten(catalog).flatMap(\.1)
    #expect(sources.count == 22)
    #expect(sources.filter { $0 == "menu:Hide sidebar" }.count == 1)
    #expect(sources.filter { $0 == "menu:Enter Full Screen" }.count == 1)
    #expect(issue219Flatten(catalog).count == 20)
}

@Test @MainActor func issue284ShortcutCatalogNamesTheSurvivingHalfOfAPairedRow() {
    let implemented = Set(CommandID.allCases).subtracting([.previous, .zoomIn])
    for (language, names) in [(EntryPointLanguage.english, ["Next Image", "Zoom Out"]),
                               (.simplifiedChinese, ["下一张", "缩小"])] {
        let catalog = ShortcutCatalog(menu: issue219Menu(), implementedCommands: implemented, language: language)
        let viewer = issue219Flatten(catalog).filter { $0.0 == "viewer" }
        let next = viewer.first { $0.1.contains("command:next") }
        let zoom = viewer.first { $0.1.contains("command:zoomOut") }
        #expect(next?.1 == ["command:next"])
        #expect(next?.2 == ["→"])
        #expect(next?.3 == names[0])
        #expect(zoom?.1 == ["command:zoomOut"])
        #expect(zoom?.2 == ["−"])
        #expect(zoom?.3 == names[1])
        #expect(!viewer.flatMap(\.1).contains("command:previous"))
        #expect(!viewer.flatMap(\.1).contains("command:zoomIn"))
    }
}

@Test @MainActor func issue284ShortcutCatalogUsesTheFirstKeyedItemWhenAnActionRepeats() throws {
    let menu = issue219Menu()
    let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
    let closeTab = NSMenuItem(title: "Close Tab", action: NSSelectorFromString("performClose:"), keyEquivalent: "w")
    closeTab.keyEquivalentModifierMask = [.shift, .command]
    file.addItem(closeTab)
    let catalog = ShortcutCatalog(menu: menu, language: .english)
    let close = issue219Flatten(catalog).filter { $0.1 == ["menu:Close"] }
    #expect(close.count == 1)
    #expect(close.first?.2 == ["⌘", "W"])
}

@Test @MainActor func issue284ShortcutCatalogResolvesMenuItemsToListedSources() {
    let catalog = ShortcutCatalog(menu: issue219Menu(), language: .english)
    func item(_ action: String?, command: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action.map(NSSelectorFromString), keyEquivalent: "")
        item.representedObject = command
        return item
    }
    #expect(catalog.source(for: item("invoke:", command: "open"))?.id == "command:open")
    #expect(catalog.source(for: item("invoke:", command: "zoomOut"))?.id == "command:zoomOut")
    #expect(catalog.source(for: item("toggleFullScreen:"))?.id == "menu:Enter Full Screen")
    #expect(catalog.source(for: item("performClose:"))?.id == "menu:Close")
    // `search` is a CommandID but the catalog lists it as a menu row, so the command source is not shown.
    #expect(catalog.source(for: item("invoke:", command: "search")) == nil)
    #expect(catalog.source(for: item("invoke:", command: "notACommand")) == nil)
    #expect(catalog.source(for: item("undo:")) == nil)
    #expect(catalog.source(for: item(nil)) == nil)

    let withoutSearch = ShortcutCatalog(menu: issue219Menu(),
        implementedCommands: Set(CommandID.allCases).subtracting([.search]), language: .english)
    #expect(withoutSearch.source(for: item("focusGridSearch:")) == nil)
    #expect(catalog.source(for: item("focusGridSearch:"))?.id == "menu:Search current folder")
}

/// #348: the catalog's zoom keycaps stay bare, and each one is still caught by a menu binding.
@Test @MainActor func zoomKeycapsAllResolve() throws {
    let zoom: Set<String> = ["command:fit", "command:actualPixels", "command:zoomIn", "command:zoomOut"]
    for language in [EntryPointLanguage.english, .simplifiedChinese] {
        let catalog = ShortcutCatalog(menu: issue219Menu(), language: language)
        let viewer = try #require(catalog.cards.first { $0.id == .viewer })
        var checked = 0
        for row in viewer.rows where row.sources.contains(where: { zoom.contains($0.id) }) {
            #expect(!row.keycaps.contains("⌘"), "\(row.name)")
            #expect(row.sources.count == row.keycaps.count)
            for (source, cap) in zip(row.sources, row.keycaps) {
                let id = try #require(CommandID(rawValue: String(source.id.dropFirst("command:".count))))
                let key = cap == "−" ? "-" : cap
                #expect(CommandID.matching(key: key, command: false) == id, "\(cap)")
                #expect(id.alternateMenuBindings.contains(CommandKeyBinding(key: key, command: false)), "\(cap)")
                checked += 1
            }
        }
        #expect(checked == 4)
    }
}
