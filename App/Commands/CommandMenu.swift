import AppKit
import MadoCore
import MadoApplication
import MadoMacUI

extension CommandID {
    var menuTitle: String {
        switch self {
        case .preview: String(localized: "Preview Selected Image")
        case .enter: String(localized: "Open Selected Image")
        case .previous: String(localized: "Previous Image")
        case .next: String(localized: "Next Image")
        case .fit: String(localized: "Fit")
        case .actualPixels: String(localized: "Actual Pixels")
        case .zoomIn: String(localized: "Zoom In")
        case .zoomOut: String(localized: "Zoom Out")
        case .open: String(localized: "Open…")
        case .inspector: String(localized: "Show Inspector")
        case .escape: String(localized: "Focus Canvas")
        default: preconditionFailure("Unimplemented commands have no menu item")
        }
    }
}

/// Bare equivalents must defer to the native field editor before menu dispatch.
final class CommandMainMenu: NSMenu {
    // NSMenu's nonisolated override runs on AppKit's main thread; the owner is main-actor bound.
    nonisolated(unsafe) weak var commandOwner: CommandMenu?

    /// ⌘ zoom items yield to a focused text field (CMD-02); other ⌘ items still match.
    /// Judged per item, so the field wins whatever character AppKit's layout localization matches.
    @MainActor static func defersToTextField(_ item: NSMenuItem) -> Bool {
        guard item.keyEquivalentModifierMask.contains(.command), !item.keyEquivalent.isEmpty,
              let raw = item.representedObject as? String, let id = CommandID(rawValue: raw) else { return false }
        return id.commandKey != nil
    }

    nonisolated(unsafe) private var yielded: [(NSMenuItem, String)] = []

    /// Makes the field's items unmatchable for one menu match; `restoreTextFieldItems` puts their keys back.
    @MainActor private func suspendTextFieldItems() {
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        yielded = items(self).filter(Self.defersToTextField).map { ($0, $0.keyEquivalent) }
        for (item, _) in yielded { item.keyEquivalent = "" }
    }

    @MainActor private func restoreTextFieldItems() {
        for (item, key) in yielded { item.keyEquivalent = key }
        yielded = []
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let allowsBareEquivalent = MainActor.assumeIsolated {
                NSApp.keyWindow?.windowController is CanvasWindowController
                    && !(NSApp.keyWindow?.firstResponder is NSTextInputClient)
            }
            guard allowsBareEquivalent else { return false }
        }
        var editing = false
        if event.modifierFlags.contains(.command) {
            let windowNumber = event.windowNumber
            editing = MainActor.assumeIsolated { [commandOwner] in
                let window = NSApp.window(withWindowNumber: windowNumber)
                    ?? commandOwner?.activeWindowController?.window ?? NSApp.keyWindow
                return window?.firstResponder is NSTextInputClient
            }
        }
        let inspectorKey = event.keyCode == 34 && event.modifierFlags.contains(.command)
            && event.modifierFlags.intersection([.control, .option, .shift]).isEmpty
        // Key equivalents may end field editing before the menu action runs.
        let owner = commandOwner
        let targetAndEditor = inspectorKey ? MainActor.assumeIsolated {
            let target = owner?.activeWindowController
            return (target, target?.captureGridSearchEditor())
        } : nil
        // AppKit itself then decides which item the event matches; the field's items cannot be it.
        nonisolated(unsafe) let menu = self
        if editing { MainActor.assumeIsolated { menu.suspendTextFieldItems() } }
        defer { if editing { MainActor.assumeIsolated { menu.restoreTextFieldItems() } } }
        let handled = super.performKeyEquivalent(with: event)
        if handled, let (target, editor) = targetAndEditor, let target, let editor {
            MainActor.assumeIsolated { target.restoreGridSearchEditor(editor) }
        }
        return handled
    }
}

@MainActor
final class CommandMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private let preferencesStore: any DisplayPreferencesStore
    private var trackingMenus: Set<ObjectIdentifier> = []
    private let openWithoutWindow: () -> Void
    private let openSettings: () -> Void
    private let openDiagnostics: () -> Void
    private let openShortcuts: () -> Void
    private let openURL: (URL) -> Void
    private let windowController: () -> CanvasWindowController?
    var activeWindowController: CanvasWindowController? { windowController() }
    private(set) var isTracking = false
    private let recentFolders = NSMenu(title: String(localized: "Open Recent"))
    private let recentTarget = RecentFolderMenuTarget()
    private let extensionMenu = NSMenu(title: String(localized: "Extensions"))

    init(preferencesStore: any DisplayPreferencesStore, openWithoutWindow: @escaping () -> Void,
         openSettings: @escaping () -> Void, openDiagnostics: @escaping () -> Void,
         openShortcuts: @escaping () -> Void = {},
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         windowController: @escaping () -> CanvasWindowController? = {
             NSApp.keyWindow?.windowController as? CanvasWindowController
         }) {
        self.preferencesStore = preferencesStore
        self.openWithoutWindow = openWithoutWindow
        self.openSettings = openSettings
        self.openDiagnostics = openDiagnostics
        self.openShortcuts = openShortcuts
        self.openURL = openURL
        self.windowController = windowController
        super.init()
        let main = CommandMainMenu(title: "Mado")
        main.commandOwner = self
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            menu.delegate = self
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("Mado")
        app.addItem(withTitle: String(localized: "About Mado"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        settings.setAccessibilityIdentifier("settings.menu")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide Mado"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit Mado"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu(String(localized: "File"))
        let edit = submenu(String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: String(localized: String.LocalizationValue(title)), action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let view = submenu(String(localized: "View"))
        let search = view.addItem(withTitle: String(localized: "Search current folder"),
            action: #selector(focusGridSearch(_:)), keyEquivalent: "f")
        search.target = self
        search.keyEquivalentModifierMask = [.command]
        search.setAccessibilityIdentifier("grid.search.menu")
        for id in CommandID.menuCommands {
            let binding = id.menuBinding
            let item = NSMenuItem(title: id.menuTitle, action: #selector(invoke(_:)), keyEquivalent: binding.key)
            item.keyEquivalentModifierMask = binding.command ? [.command] : []
            item.representedObject = id.rawValue
            item.setAccessibilityIdentifier("command.\(id.rawValue).menu")
            item.target = self
            (id == .open ? file : view).addItem(item)
        }
        // Hidden alternates keep the bare keys on their old menu path; they follow every shown item.
        for id in CommandID.menuCommands {
            for (index, binding) in id.alternateMenuBindings.enumerated() {
                let item = NSMenuItem(title: id.menuTitle, action: #selector(invoke(_:)), keyEquivalent: binding.key)
                item.keyEquivalentModifierMask = binding.command ? [.command] : []
                item.representedObject = id.rawValue
                item.setAccessibilityIdentifier("command.\(id.rawValue).menu.alt.\(index)")
                item.target = self
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
                (id == .open ? file : view).addItem(item)
            }
        }
        let always = view.addItem(withTitle: String(localized: "Always Show Tools"), action: #selector(toggleAlwaysShowTools(_:)), keyEquivalent: "")
        always.target = self
        always.identifier = NSUserInterfaceItemIdentifier("chrome.always-show-tools")
        always.setAccessibilityIdentifier("chrome.always-show-tools.menu")
        let sidebar = view.addItem(withTitle: String(localized: "Hide sidebar"), action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        sidebar.target = self
        sidebar.identifier = NSUserInterfaceItemIdentifier("grid.sidebar.toggle.menu")
        sidebar.setAccessibilityIdentifier("grid.sidebar.toggle.menu")
        let appearanceMenu = NSMenu(title: String(localized: "Appearance"))
        appearanceMenu.delegate = self
        let appearanceItem = NSMenuItem(title: String(localized: "Appearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        appearanceItem.setAccessibilityIdentifier("prefs.appearance.menu")
        view.addItem(appearanceItem)
        let appearances: [(DisplayAppearance, String)] = [(.system, String(localized: "System")),
            (.light, String(localized: "Light")), (.dark, String(localized: "Dark"))]
        for (appearance, title) in appearances {
            let item = appearanceMenu.addItem(withTitle: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appearance.rawValue
            item.setAccessibilityIdentifier("prefs.appearance.\(appearance.rawValue).menu")
        }
        let sortMenu = NSMenu(title: String(localized: "Sort By"))
        sortMenu.delegate = self
        let sortItem = NSMenuItem(title: sortMenu.title, action: nil, keyEquivalent: "")
        sortItem.submenu = sortMenu
        sortItem.setAccessibilityIdentifier("folder.sort.menu")
        view.addItem(sortItem)
        for key in FolderSortKey.allCases { addFolderItem(.sort(key), to: sortMenu) }
        let orderMenu = NSMenu(title: String(localized: "Sort Order"))
        orderMenu.delegate = self
        let orderItem = NSMenuItem(title: orderMenu.title, action: nil, keyEquivalent: "")
        orderItem.submenu = orderMenu
        orderItem.setAccessibilityIdentifier("folder.order.menu")
        view.addItem(orderItem)
        for direction in FolderSortDirection.allCases { addFolderItem(.direction(direction), to: orderMenu) }
        extensionMenu.delegate = self
        let extensionItem = NSMenuItem(title: extensionMenu.title, action: nil, keyEquivalent: "")
        extensionItem.submenu = extensionMenu
        extensionItem.setAccessibilityIdentifier("folder.extensions.menu")
        view.addItem(extensionItem)
        addFolderItem(.loop, to: view)
        addFolderItem(.recursive, to: view)
        view.addItem(.separator())
        // #690: Annotate Mode on the shown image (⌘E); R, Esc and ⌘S work inside it.
        let annotate = view.addItem(withTitle: String(localized: "Annotate"), action: #selector(enterAnnotate(_:)), keyEquivalent: "e")
        annotate.keyEquivalentModifierMask = [.command]
        annotate.target = self
        annotate.identifier = NSUserInterfaceItemIdentifier("annotate.enter.menu")
        annotate.setAccessibilityIdentifier("annotate.enter.menu")
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: String(localized: "Enter Full Screen"),
            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        let recentItem = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recentFolders
        recentFolders.autoenablesItems = false
        recentFolders.delegate = self
        file.addItem(recentItem)
        setRecentFolders([], onOpen: { _ in })
        ChromeWindowCommands.addClose(to: file)
        let saveCopy = file.addItem(withTitle: String(localized: "Save Annotated Copy"), action: #selector(saveAnnotatedCopy(_:)),
            keyEquivalent: "s")
        saveCopy.keyEquivalentModifierMask = [.command]
        saveCopy.target = self
        saveCopy.identifier = NSUserInterfaceItemIdentifier("annotate.save.menu")
        saveCopy.setAccessibilityIdentifier("annotate.save.menu")
        let windows = submenu(String(localized: "Window"))
        windows.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        #if DEBUG
        let preview = windows.addItem(withTitle: String(localized: "Component Preview"), action: #selector(DesignPreviewLauncher.openPreview(_:)), keyEquivalent: "")
        preview.target = DesignPreviewLauncher.shared
        #endif
        let help = submenu(String(localized: "Help"))
        help.autoenablesItems = false
        let report = help.addItem(withTitle: String(localized: "Report a Problem…"), action: #selector(reportIssue(_:)), keyEquivalent: "")
        report.target = self
        report.identifier = NSUserInterfaceItemIdentifier("help.report-issue.menu")
        report.setAccessibilityIdentifier("help.report-issue.menu")
        let diagnostics = help.addItem(withTitle: String(localized: "Diagnostics"), action: #selector(showDiagnostics(_:)), keyEquivalent: "")
        diagnostics.target = self
        diagnostics.identifier = NSUserInterfaceItemIdentifier("diagnostics.menu")
        diagnostics.setAccessibilityIdentifier("diagnostics.menu")
        let shortcutEntry = EntryPoint.keyboardShortcuts
        let shortcutMarker = shortcutEntry.accessibilityLabel(for: .preferred)
        let shortcutTitle = [String(localized: "Keyboard Shortcuts"), shortcutMarker].filter { !$0.isEmpty }.joined(separator: " · ")
        let shortcuts = help.addItem(withTitle: shortcutTitle,
            action: shortcutEntry.isEnabled ? #selector(showShortcuts(_:)) : nil,
            keyEquivalent: shortcutEntry.keyEquivalent ?? "")
        shortcuts.target = self
        shortcuts.isEnabled = shortcutEntry.isEnabled
        shortcuts.representedObject = shortcutEntry.rawValue
        shortcuts.identifier = NSUserInterfaceItemIdentifier("help.keyboard-shortcuts.menu")
        shortcuts.setAccessibilityIdentifier("help.keyboard-shortcuts.menu")
        shortcuts.setAccessibilityLabel(shortcutTitle)
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    func setRecentFolders(_ folders: [RecentFolder], onOpen: @escaping (RecentFolder) -> Void) {
        recentTarget.onOpen = onOpen
        recentFolders.removeAllItems()
        if folders.isEmpty {
            let empty = recentFolders.addItem(withTitle: String(localized: "No Recent Folders"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for folder in folders {
            let item = recentFolders.addItem(withTitle: folder.displayName, action: #selector(RecentFolderMenuTarget.open(_:)), keyEquivalent: "")
            item.target = recentTarget
            item.representedObject = folder
        }
    }

    /// #444: page 14's 「更多浏览操作」 menu, implemented items only: the file name, 显示/隐藏图片信息, 外观, 始终显示工具,
    /// 键盘快捷键. 收藏图片 (GRID-12) and 显示缩略图条 (FILM-01) are not built yet, so they are not listed. Each item
    /// uses the same action and represented object as its main-menu twin, so validation and effects are shared.
    func makeViewerMoreMenu(fileName: String?) -> NSMenu {
        let menu = NSMenu(title: String(localized: "More browse actions"))
        if let fileName { menu.addItem(.sectionHeader(title: fileName)) }
        let inspector = menu.addItem(withTitle: String(localized: "Show image information"), action: #selector(invoke(_:)),
                                     keyEquivalent: "")
        inspector.target = self
        inspector.representedObject = CommandID.inspector.rawValue
        inspector.identifier = NSUserInterfaceItemIdentifier("viewer.more.inspector")
        menu.addItem(.separator())
        // No delegate: closing this submenu must not end the App menu tracking that CommandMenu counts.
        let appearanceMenu = NSMenu(title: String(localized: "Appearance"))
        for (appearance, title) in [(DisplayAppearance.system, String(localized: "System")),
                                    (.light, String(localized: "Light")), (.dark, String(localized: "Dark"))] {
            let item = appearanceMenu.addItem(withTitle: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appearance.rawValue
        }
        let appearanceItem = menu.addItem(withTitle: appearanceMenu.title, action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        let always = menu.addItem(withTitle: String(localized: "Always Show Tools"), action: #selector(toggleAlwaysShowTools(_:)),
                                  keyEquivalent: "")
        always.target = self
        always.identifier = NSUserInterfaceItemIdentifier("chrome.always-show-tools")
        let shortcuts = menu.addItem(withTitle: String(localized: "Keyboard Shortcuts"), action: #selector(showShortcuts(_:)),
                                     keyEquivalent: "")
        shortcuts.target = self
        shortcuts.representedObject = EntryPoint.keyboardShortcuts.rawValue
        return menu
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let id = CommandID(rawValue: raw) else { return }
        if let target = windowController() {
            let searchEditor = id == .inspector ? target.captureGridSearchEditor() : nil
            let handled = target.route(id, from: .menu,
                commandModified: item.keyEquivalentModifierMask.contains(.command))
            if handled, let searchEditor { target.restoreGridSearchEditor(searchEditor) }
        } else if id == .open { openWithoutWindow() }
    }

    @objc private func showSettings(_ item: NSMenuItem) { openSettings() }
    @objc private func enterAnnotate(_ item: NSMenuItem) { windowController()?.enterAnnotateMode() }
    @objc private func saveAnnotatedCopy(_ item: NSMenuItem) { windowController()?.saveAnnotatedCopy() }
    @objc private func showDiagnostics(_ item: NSMenuItem) { openDiagnostics() }
    @objc private func showShortcuts(_ item: NSMenuItem) { openShortcuts() }
    @objc private func reportIssue(_ item: NSMenuItem) { openURL(EntryPoint.reportIssueURL) }

    @objc private func toggleAlwaysShowTools(_ item: NSMenuItem) {
        var value = preferencesStore.value
        value.alwaysShowTools.toggle()
        preferencesStore.value = value
    }
    @objc private func toggleSidebar(_ item: NSMenuItem) {
        windowController()?.toggleGridSidebar()
    }
    @objc private func focusGridSearch(_ item: NSMenuItem) {
        windowController()?.route(.search, from: .menu)
    }
    @objc private func selectAppearance(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let appearance = DisplayAppearance(rawValue: raw) else { return }
        preferencesStore.value.appearance = appearance
    }
    private func addFolderItem(_ action: FolderMenuAction, to menu: NSMenu) {
        let title: String
        if case .extensionType(let value) = action, !value.isEmpty { title = value.uppercased() }
        else { title = String(localized: String.LocalizationValue(action.titleKey)) }
        let item = menu.addItem(withTitle: title, action: #selector(invokeFolder(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        item.setAccessibilityIdentifier(action.accessibilityIdentifier)
        if let help = action.helpKey { item.toolTip = String(localized: String.LocalizationValue(help)) }
    }
    @objc private func invokeFolder(_ item: NSMenuItem) {
        guard let action = item.representedObject as? FolderMenuAction else { return }
        if action == .loop {
            preferencesStore.value.loopThroughImages.toggle()
            return
        }
        guard let session = windowController()?.session,
              session.hasFolderSource, session.filePreviewSet == nil, session.previewSet == nil else { return }
        let selection = FolderMenuSelection(conditions: session.folderConditions, loopEnabled: session.folderLoopEnabled,
            recursiveEnabled: session.folderRecursiveEnabled)
        let changed = FolderMenuPolicy.applying(action, to: selection)
        session.setFolderConditions(changed.conditions)
        session.setFolderRecursiveEnabled(changed.recursiveEnabled)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showSettings(_:)) || item.action == #selector(showDiagnostics(_:))
            || item.action == #selector(showShortcuts(_:)) || item.action == #selector(reportIssue(_:)) { return true }
        if item.action == #selector(enterAnnotate(_:)) { return windowController()?.canEnterAnnotateFromMenu == true }
        if item.action == #selector(saveAnnotatedCopy(_:)) { return windowController()?.canSaveAnnotatedCopyFromMenu == true }
        if let raw = item.representedObject as? String, let entry = EntryPoint(rawValue: raw), entry.state == .comingSoon {
            item.isEnabled = false
            item.keyEquivalent = ""
            return false
        }
        if let action = item.representedObject as? FolderMenuAction {
            let session = windowController()?.session
            let selection = FolderMenuSelection(conditions: session?.folderConditions ?? .init(),
                loopEnabled: preferencesStore.value.loopThroughImages, recursiveEnabled: session?.folderRecursiveEnabled ?? false)
            let state = FolderMenuPolicy.state(for: action, selection: selection,
                hasFolderSource: session?.hasFolderSource == true,
                previewActive: session?.filePreviewSet != nil || session?.previewSet != nil)
            item.state = state.checked ? .on : .off
            return state.enabled
        }
        if item.action == #selector(selectAppearance(_:)),
           let raw = item.representedObject as? String, let appearance = DisplayAppearance(rawValue: raw) {
            item.state = preferencesStore.value.appearance == appearance ? .on : .off
            return true
        }
        if item.identifier?.rawValue == "chrome.always-show-tools" {
            item.state = preferencesStore.value.alwaysShowTools ? .on : .off
            return true
        }
        if item.identifier?.rawValue == "grid.sidebar.toggle.menu" {
            let shown = windowController()?.viewerSidebarMenuState ?? preferencesStore.value.gridSidebarVisible
            item.title = String(localized: shown ? "Hide sidebar" : "Show sidebar")
            return windowController()?.sidebarToggleAvailable == true
        }
        if item.action == #selector(focusGridSearch(_:)) {
            return (NSApp.keyWindow?.windowController as? CanvasWindowController)?.gridSearchAvailable == true
        }
        guard let raw = item.representedObject as? String, let id = CommandID(rawValue: raw) else { return false }
        let target = windowController()
        if id == .inspector {
            let visible = target?.inspectorVisible == true
            // The viewer's 更多 menu keeps page 14's wording; View › Show Inspector keeps its own.
            item.title = item.identifier?.rawValue == "viewer.more.inspector"
                ? String(localized: visible ? "Hide image information" : "Show image information")
                : String(localized: visible ? "Hide Inspector" : "Show Inspector")
        }
        return target?.session.isEnabled(id,
            commandModified: item.keyEquivalentModifierMask.contains(.command)) ?? (id == .open)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === extensionMenu else { return }
        extensionMenu.removeAllItems()
        addFolderItem(.clearFilter, to: extensionMenu)
        extensionMenu.addItem(.separator())
        let session = (NSApp.keyWindow?.windowController as? CanvasWindowController)?.session
        let available = (session?.folderAvailableExtensions ?? []) + Array(session?.folderConditions.selectedExtensions ?? [])
        for value in FolderMenuPolicy.extensionChoices(available: available) {
            addFolderItem(.extensionType(value), to: extensionMenu)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        trackingMenus.insert(ObjectIdentifier(menu))
        isTracking = true
        (NSApp.keyWindow?.windowController as? CanvasWindowController)?.session.setMenuTracking(true)
    }
    func menuDidClose(_ menu: NSMenu) {
        trackingMenus.remove(ObjectIdentifier(menu))
        isTracking = !trackingMenus.isEmpty
        guard !isTracking else { return }
        // The key window can change during menu tracking. Release the original window too.
        for window in NSApp.windows {
            (window.windowController as? CanvasWindowController)?.session.setMenuTracking(false)
        }
    }
}
