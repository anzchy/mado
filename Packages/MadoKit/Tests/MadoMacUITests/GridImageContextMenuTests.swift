import AppKit
import Testing
import MadoMacUI

@Test @MainActor func imageContextMenuItemsMatchPage31OrderWithoutFavorite() throws {
    let menu = GridImageContextMenu(onAction: { _ in }).menu
    let items = try #require(menu.items.count == 5 ? menu.items : nil)
    #expect(items.map(\.title) == ["Quick Look", "", "Show in Finder", "Copy Path", "Get Info"])
    #expect(items[1].isSeparatorItem)
    #expect(items.filter(\.isSeparatorItem).count == 1)
    #expect(items[0].keyEquivalent == " ")
    #expect(items[0].keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]).isEmpty)
    #expect(items.dropFirst().allSatisfy { $0.keyEquivalent.isEmpty })
    #expect(items.allSatisfy { $0.view == nil && $0.image == nil })
    #expect(menu.title == "Image Context Menu")
}

@Test @MainActor func imageContextMenuRevalidatesAndInvokesOnlyAvailableAction() throws {
    _ = NSApplication.shared
    var actions: [GridImageContextMenu.Action] = []
    let owner = GridImageContextMenu { actions.append($0) }
    var opens = 0, closes = 0
    owner.onOpen = { opens += 1 }
    owner.onClose = { closes += 1 }
    owner.isAvailable = { $0 == .copyPath }
    owner.menuNeedsUpdate(owner.menu)
    #expect(owner.menu.items[0].isEnabled == false)
    #expect(owner.menu.items[3].isEnabled)
    owner.menuWillOpen(owner.menu)
    owner.menuDidClose(owner.menu)
    #expect(opens == 1 && closes == 1)
    let copy = owner.menu.items[3]
    _ = NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy)
    #expect(actions == [.copyPath])
    owner.isAvailable = { _ in false }
    _ = NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy)
    #expect(actions == [.copyPath])
}
