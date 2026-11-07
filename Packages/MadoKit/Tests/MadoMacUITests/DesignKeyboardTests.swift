import SwiftUI
import Testing
@testable import MadoMacUI

@MainActor @Test func designKeyboardCommandsActivateExactlyOnce() {
    for input in [ComponentInput.forced, .live] {
        for state: ComponentState in [[], .disabled] {
            var calls = 0
            let icon = IconCommandButton(symbol: .next, state: state, theme: .light, input: input) { calls += 1 }
            let folder = FolderNavigationRow(nodeID: "id", name: "Folder", count: nil, expanded: false, state: state, theme: .light, input: input, onSelect: { calls += 1 }, onExpand: { calls += 1 })
            #expect(icon.activateFromKeyboard() == (input == .live ? .handled : .ignored))
            #expect(calls == (input == .live && !state.contains(.disabled) ? 1 : 0))
            _ = folder.selectFromKeyboard()
            #expect(calls == (input == .live && !state.contains(.disabled) ? 2 : 0))
            _ = folder.expandFromKeyboard()
            #expect(calls == (input == .live && !state.contains(.disabled) ? 3 : 0))
        }
    }
}
