import AppKit
import Testing
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func gridSelectAllMenuIsDisabledUntilModelSemanticsExist() {
    _ = NSApplication.shared
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let menuItem = NSMenuItem(title: "Select All", action: #selector(NSCollectionView.selectAll(_:)),
        keyEquivalent: "a")
    let validator = grid.collectionView as? NSUserInterfaceValidations
    #expect(validator?.validateUserInterfaceItem(menuItem) == false)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridMenuValidationKeepsOtherNativeActionsAvailable() throws {
    _ = NSApplication.shared
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let validator = try #require(grid.collectionView as? NSUserInterfaceValidations)
    let deselect = NSMenuItem(title: "Deselect All",
        action: #selector(NSCollectionView.deselectAll(_:)), keyEquivalent: "")
    #expect(validator.validateUserInterfaceItem(deselect))
    let noAction = NSMenuItem(title: "No Action", action: nil, keyEquivalent: "")
    #expect(!validator.validateUserInterfaceItem(noAction))
}
