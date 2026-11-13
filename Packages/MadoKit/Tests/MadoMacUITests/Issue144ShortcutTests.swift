import AppKit
import Testing
import MadoMacUI

@Test @MainActor func issue144ControlReturnAppearsInGridShortcutCatalog() throws {
    let catalog = ShortcutCatalog(menu: NSMenu(), language: .english)
    let grid = try #require(catalog.cards.first { $0.id == .grid })
    let row = try #require(grid.rows.first { $0.sources.contains(ShortcutSource(id: "key:grid-context-menu")) })
    #expect(row.name == "Image Context Menu")
    #expect(row.keycaps == ["⌃", "Return"])
}
