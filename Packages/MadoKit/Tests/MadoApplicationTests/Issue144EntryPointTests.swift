import Testing
import MadoApplication

@Test func issue144GridContextMenuEntryPointIsImplemented() {
    #expect(EntryPoint.contextMenu.state == .implemented)
    #expect(EntryPoint.contextMenu.isEnabled)
    #expect(EntryPoint.contextMenu.isFocusable)
}
