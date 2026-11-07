import AppKit
import Testing
import MadoApplication
import MadoInfrastructure

@MainActor @Test func issue215HelpMenuMovesDiagnosticsAndReportsBugTemplate() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    var openedURLs: [URL] = []
    var diagnosticsCount = 0
    var shortcutsCount = 0
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: { diagnosticsCount += 1 },
        openShortcuts: { shortcutsCount += 1 }, openURL: { openedURLs.append($0) }, windowController: { nil })
    defer { NSApp.mainMenu = previousMenu; withExtendedLifetime(menu) {} }
    let main = try #require(NSApp.mainMenu)
    func submenu(_ title: String) throws -> NSMenu {
        try #require(main.items.first { $0.title == title }?.submenu)
    }
    let help = try submenu("Help")
    let window = try submenu("Window")
    #expect(help.items.count == 3)
    #expect(help.items.map(\.identifier?.rawValue) == [
        "help.report-issue.menu", "diagnostics.menu", "help.keyboard-shortcuts.menu",
    ])
    #expect(window.items.contains { $0.identifier?.rawValue == "diagnostics.menu" } == false)

    let report = help.items[0]
    #expect(EntryPoint.reportIssueURL.absoluteString == "https://github.com/anzchy/mado/issues/new?template=bug_report.yml")
    #expect(menu.validateMenuItem(report))
    #expect(NSApp.sendAction(try #require(report.action), to: report.target, from: report))
    #expect(openedURLs == [EntryPoint.reportIssueURL])

    let diagnostics = help.items[1]
    #expect(menu.validateMenuItem(diagnostics))
    #expect(NSApp.sendAction(try #require(diagnostics.action), to: diagnostics.target, from: diagnostics))
    #expect(diagnosticsCount == 1)

    let shortcuts = help.items[2]
    #expect(menu.validateMenuItem(shortcuts))
    #expect(shortcuts.isEnabled)
    #expect(shortcuts.keyEquivalent.isEmpty)
    #expect(shortcuts.action != nil)
    #expect(shortcuts.title == String(localized: "Keyboard Shortcuts"))
    #expect(NSApp.sendAction(try #require(shortcuts.action), to: shortcuts.target, from: shortcuts))
    #expect(shortcutsCount == 1)
}
