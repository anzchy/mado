import Foundation
import Testing
import MadoCore
import MadoApplication

@Test(arguments: [false, true], [false, true])
func issue344LoopMenuStateIsGlobal(loop: Bool, folder: Bool) {
    for preview in [false, true] {
    let selection = FolderMenuSelection(conditions: .init(sort: .size, direction: .descending,
        selectedExtensions: ["png"]), loopEnabled: loop, recursiveEnabled: true)
    #expect(FolderMenuPolicy.state(for: .loop, selection: selection, hasFolderSource: folder,
        previewActive: preview) == .init(enabled: folder || preview, checked: loop))
    for action in [FolderMenuAction.sort(.size), .direction(.descending), .extensionType("png"), .clearFilter, .recursive] {
        #expect(FolderMenuPolicy.state(for: action, selection: selection, hasFolderSource: folder,
            previewActive: preview).enabled == (folder && !preview))
    }
    }
}

@Test(arguments: [false, true]) @MainActor
func issue344LoopMenuSharedTogglePreservesOtherPreferences(initial: Bool) {
    var value = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true, appearance: .dark,
                                   gridSidebarWidth: 284, gridSidebarVisible: false)
    value.folderSort = .size
    value.folderSortDirection = .descending
    value.loopThroughImages = initial
    let store = InMemoryDisplayPreferencesStore(value)
    let first = ViewerSession(preferencesStore: store), second = ViewerSession(preferencesStore: store)
    for window in [first, second] {
        let selection = FolderMenuSelection(conditions: window.folderConditions, loopEnabled: window.folderLoopEnabled)
        let changed = FolderMenuPolicy.applying(.loop, to: selection)
        window.setFolderLoopEnabled(changed.loopEnabled)
        value.loopThroughImages.toggle()
        #expect(first.displayPreferences == value && second.displayPreferences == value)
        for session in [first, second] {
            let state = FolderMenuPolicy.state(for: .loop,
                selection: .init(conditions: session.folderConditions, loopEnabled: session.folderLoopEnabled),
                hasFolderSource: false, previewActive: true)
            #expect(state.enabled && state.checked == value.loopThroughImages)
        }
    }
    #expect(store.value.loopThroughImages == initial)
}

@Test func issue344LoopMenuCatalogUsesNewBilingualTitle() throws {
    #expect(FolderMenuAction.loop.titleKey == "Loop Through Images")
    #expect(FolderMenuAction.loop.accessibilityIdentifier == "folder.loop.menu")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    #expect(strings["Loop Through Folder"] == nil)
    let entry = try #require(strings["Loop Through Images"] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    for (language, title) in [("en", "Loop Through Images"), ("zh-Hans", "循环浏览")] {
        let localized = try #require(localizations[language] as? [String: Any])
        let unit = try #require(localized["stringUnit"] as? [String: Any])
        #expect(unit["value"] as? String == title)
    }
}
