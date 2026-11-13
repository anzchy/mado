import AppKit
import MadoCore
import MadoApplication

public struct ShortcutSource: Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct ShortcutRow: Sendable {
    public let sources: [ShortcutSource]
    public let name: String
    public let keycaps: [String]
}

public struct ShortcutCard: Sendable {
    public enum ID: String, Sendable { case files, grid, viewer }
    public let id: ID
    public let title: String
    public let when: String
    public let rows: [ShortcutRow]
}

private let shortcutMenuSourceIDs = [
    "showSettings:": "Settings…",
    "performClose:": "Close",
    "performMiniaturize:": "Minimize",
    "hide:": "Hide Mado",
    "hideOtherApplications:": "Hide Others",
    "terminate:": "Quit Mado",
    "focusGridSearch:": "Search current folder",
    "toggleSidebar:": "Hide sidebar",
    "toggleFullScreen:": "Enter Full Screen",
]

public struct ShortcutCatalog: Sendable {
    public let cards: [ShortcutCard]

    @MainActor public init(menu: NSMenu,
                           implementedCommands: Set<CommandID> = Set(CommandID.allCases.filter(\.isImplemented)),
                           language: EntryPointLanguage = .preferred) {
        struct MenuKey {
            let key: String
            let modifiers: NSEvent.ModifierFlags
        }
        var menuKeys: [String: [MenuKey]] = [:]
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { collect(submenu) }
                if !item.keyEquivalent.isEmpty, let action = item.action {
                    menuKeys[NSStringFromSelector(action), default: []].append(
                        MenuKey(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask))
                }
            }
        }
        collect(menu)

        func text(_ english: String, _ chinese: String) -> String {
            language == .simplifiedChinese ? chinese : english
        }
        func source(_ id: String) -> ShortcutSource { ShortcutSource(id: id) }
        func commandSource(_ id: CommandID) -> ShortcutSource { source("command:\(id.rawValue)") }
        func commandRow(_ commands: [CommandID], _ english: String, _ chinese: String,
                        singleNames: [(String, String)] = []) -> ShortcutRow? {
            let available = commands.filter(implementedCommands.contains)
            guard !available.isEmpty else { return nil }
            let name: String
            if available.count == commands.count || singleNames.isEmpty {
                name = text(english, chinese)
            } else {
                let index = commands.firstIndex(of: available[0])!
                name = text(singleNames[index].0, singleNames[index].1)
            }
            return ShortcutRow(sources: available.map(commandSource), name: name,
                keycaps: available.flatMap { shortcutKeycaps($0.defaultKey, command: $0.usesCommand) })
        }
        func menuRow(_ action: String, _ english: String, _ chinese: String,
                     requiredCommand: CommandID? = nil) -> ShortcutRow? {
            guard let sourceID = shortcutMenuSourceIDs[action],
                  let item = menuKeys[action]?.first else { return nil }
            if let requiredCommand, !implementedCommands.contains(requiredCommand) { return nil }
            return ShortcutRow(sources: [source("menu:\(sourceID)")], name: text(english, chinese),
                keycaps: shortcutKeycaps(item.key, modifiers: item.modifiers))
        }
        func keyRow(_ id: String, _ keycaps: [String], _ english: String, _ chinese: String) -> ShortcutRow {
            ShortcutRow(sources: [source("key:\(id)")], name: text(english, chinese), keycaps: keycaps)
        }

        let files = [
            commandRow([.open], "Open…", "打开…"),
            menuRow("showSettings:", "Settings…", "设置…"),
            menuRow("performClose:", "Close Window", "关闭窗口"),
            menuRow("performMiniaturize:", "Minimize", "最小化"),
            menuRow("hide:", "Hide Mado", "隐藏 Mado"),
            menuRow("hideOtherApplications:", "Hide Others", "隐藏其他"),
            menuRow("terminate:", "Quit Mado", "退出 Mado"),
        ].compactMap { $0 }
        let grid = [
            keyRow("grid-arrows", ["←", "→", "↑", "↓"], "Move Current", "移动当前项"),
            commandRow([.preview], "Preview Current Item", "用大图查看当前项"),
            commandRow([.enter], "Open Current Item", "打开当前项"),
            keyRow("grid-context-menu", ["⌃", "Return"], "Image Context Menu", "图片上下文菜单"),
            menuRow("focusGridSearch:", "Search Current Folder", "搜索当前文件夹", requiredCommand: .search),
            menuRow("toggleSidebar:", "Show / Hide Sidebar", "显示 / 隐藏侧栏"),
        ].compactMap { $0 }
        let viewer = [
            commandRow([.previous, .next], "Previous / Next Image", "上一张 / 下一张",
                singleNames: [("Previous Image", "上一张"), ("Next Image", "下一张")]),
            commandRow([.escape], "Return to Grid", "回到网格"),
            commandRow([.fit], "Fit Window", "适应窗口"),
            commandRow([.actualPixels], "Actual Pixels", "实际像素"),
            commandRow([.zoomIn, .zoomOut], "Zoom In / Out", "放大 / 缩小",
                singleNames: [("Zoom In", "放大"), ("Zoom Out", "缩小")]),
            keyRow("viewer-tab", ["Tab"], "Recall Tools", "唤回工具"),
            commandRow([.inspector], "Image Information", "图片信息"),
            menuRow("toggleFullScreen:", "Toggle Full Screen", "进入 / 退出全屏"),
        ].compactMap { $0 }
        cards = [
            ShortcutCard(id: .files, title: text("Files & Windows", "文件与窗口"),
                when: text("Anytime", "任何时候"), rows: files),
            ShortcutCard(id: .grid, title: text("Grid", "网格"),
                when: text("While Browsing a Folder", "浏览文件夹时"), rows: grid),
            ShortcutCard(id: .viewer, title: text("Image Viewer", "大图"),
                when: text("While Viewing One Image", "查看一张图片时"), rows: viewer),
        ]
    }

    @MainActor public func source(for item: NSMenuItem) -> ShortcutSource? {
        let source: ShortcutSource?
        if let raw = item.representedObject as? String, let id = CommandID(rawValue: raw) {
            source = ShortcutSource(id: "command:\(id.rawValue)")
        } else if let action = item.action, let id = shortcutMenuSourceIDs[NSStringFromSelector(action)] {
            source = ShortcutSource(id: "menu:\(id)")
        } else {
            source = nil
        }
        guard let source else { return nil }
        return cards.flatMap(\.rows).flatMap(\.sources).contains(source) ? source : nil
    }
}

private func shortcutKeycaps(_ key: String, command: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> [String] {
    var result: [String] = []
    if modifiers.contains(.control) { result.append("⌃") }
    if modifiers.contains(.option) { result.append("⌥") }
    if modifiers.contains(.shift) { result.append("⇧") }
    if command || modifiers.contains(.command) { result.append("⌘") }
    let glyph = switch key {
    case " ": "Space"
    case "\r": "Return"
    case "\u{1b}": "Esc"
    case "\t": "Tab"
    case "\u{f702}": "←"
    case "\u{f703}": "→"
    case "\u{f700}": "↑"
    case "\u{f701}": "↓"
    case "-": "−"
    default: key.uppercased()
    }
    return result + [glyph]
}
