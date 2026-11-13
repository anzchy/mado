import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

/// #238 (P3-17c D3): the footer and sidebar while 「读取失败」 (24F-A) shows.
@MainActor private func readFailedShell(width: CGFloat = 1280, height: CGFloat = 772, current: Int? = nil)
    -> (NSWindow, GridShellView, URL, URL) {
    _ = NSApplication.shared
    let size = NSSize(width: width, height: height)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let shell = GridShellView(frame: NSRect(origin: .zero, size: size), preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    let folder = URL(fileURLWithPath: "/read-failed/待整理"), child = folder.appendingPathComponent("B")
    shell.showFolderTree(current: GridSidebarFolder(url: folder, count: current), parent: nil,
                         children: [GridSidebarFolder(url: child, count: 4)])
    shell.layoutSubtreeIfNeeded()
    return (window, shell, folder, child)
}

@MainActor private func readFailedFind<T: NSView>(_ type: T.Type, in view: NSView, _ match: (T) -> Bool) -> T? {
    if let view = view as? T, match(view) { return view }
    for subview in view.subviews { if let found = readFailedFind(type, in: subview, match) { return found } }
    return nil
}

@MainActor private func readFailedFooter(_ shell: GridShellView) throws -> (name: NSTextField, count: NSTextField) {
    shell.layoutSubtreeIfNeeded()
    return (try #require(readFailedFind(NSTextField.self, in: shell) { $0.accessibilityIdentifier() == "grid.current-file-status" }),
            try #require(readFailedFind(NSTextField.self, in: shell) { $0.accessibilityIdentifier() == "grid.folder-count" }))
}

@MainActor private func readFailedRow(_ shell: GridShellView, _ url: URL) throws -> GridSidebarFolderButton {
    try #require(readFailedFind(GridSidebarFolderButton.self, in: shell.folderTree) { $0.folderURL == url })
}

@Test(.timeLimit(.minutes(2)), arguments: [(1280, 772, nil), (1280, 772, 7), (800, 680, nil)] as [(Int, Int, Int?)])
@MainActor func gridShellReadFailedFooterAndSidebarDash(width: Int, height: Int, current: Int?) throws {
    let (window, shell, folder, child) = readFailedShell(width: CGFloat(width), height: CGFloat(height), current: current)
    defer { window.close() }
    shell.setCurrentFile("img1.png")
    shell.setSearchStatus(resultCount: 3, term: "")
    shell.setReadFailedStatus(true)
    let (name, count) = try readFailedFooter(shell)
    #expect(name.stringValue == "\u{2014}" && !name.isHidden)
    #expect(count.stringValue == String(localized: "Read incomplete") && count.stringValue == "Read incomplete")
    #expect(!count.isHidden && count.frame.width >= ceil(count.cell?.cellSize.width ?? .infinity))
    let row = try readFailedRow(shell, folder)
    #expect(row.countLabel.stringValue == "\u{2014}" && !row.countLabel.isHidden)
    #expect(row.accessibilityLabel() == "待整理, Read incomplete")
    #expect(try readFailedRow(shell, child).countLabel.stringValue == "4")
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridShellReadFailedDisablesSearchSortInfoOnly() throws {
    let (window, shell, _, child) = readFailedShell()
    defer { window.close() }
    shell.setFooterActionsEnabled(true)
    let infoBefore = shell.infoButton.isEnabled, displayBefore = shell.displayButton.isEnabled
    let favoritesBefore = shell.favoritesButton.isEnabled, recentsBefore = shell.recentsButton.isEnabled
    var selected: [URL] = []
    shell.onSelectFolder = { selected.append($0) }
    shell.setReadFailedStatus(true)
    #expect(!shell.searchButton.isEnabled && !shell.sortButton.isEnabled && !shell.searchField.isEnabled)
    #expect(!shell.infoButton.isEnabled)
    #expect(shell.displayButton.isEnabled == displayBefore && shell.toggleButton.isEnabled)
    #expect(shell.favoritesButton.isEnabled == favoritesBefore && shell.recentsButton.isEnabled == recentsBefore)
    try readFailedRow(shell, child).performClick(nil)
    #expect(selected == [child])
    shell.setReadFailedStatus(false)
    #expect(shell.searchButton.isEnabled && shell.sortButton.isEnabled && shell.infoButton.isEnabled == infoBefore)
}

enum GridFooterMode: CaseIterable, Sendable { case normal, reading, failed }

@Test(.timeLimit(.minutes(2))) @MainActor func gridShellStatusTransitionsRestoreStoredFooter() throws {
    let modes = GridFooterMode.allCases
    let sequences = modes.flatMap { a in modes.map { [a, $0] } } + modes.flatMap { a in modes.flatMap { b in modes.map { [a, b, $0] } } }
    for (index, sequence) in sequences.enumerated() {
        let (window, shell, folder, _) = readFailedShell(current: index.isMultiple(of: 2) ? nil : 5)
        defer { window.close() }
        shell.setFooterActionsEnabled(true)
        shell.setCurrentFile("start.png"); shell.setSearchStatus(resultCount: 1, term: "")
        var name = "start.png", count = "1 images"
        for (step, mode) in (sequence + [.normal]).enumerated() {
            shell.setReadFailedStatus(mode == .failed)
            shell.setReadingStatus(mode == .reading)
            if mode == .failed { shell.setReadFailedStatus(true) }
            let label = "\(sequence) step \(step)"
            let footer = try readFailedFooter(shell)
            switch mode {
            case .failed:
                #expect(footer.name.stringValue == "\u{2014}" && footer.count.stringValue == "Read incomplete", "\(label)")
                #expect(try readFailedRow(shell, folder).countLabel.stringValue == "\u{2014}", "\(label)")
                #expect(!shell.searchButton.isEnabled && !shell.sortButton.isEnabled, "\(label)")
            case .reading:
                #expect(footer.name.stringValue == "\u{2014}" && footer.count.stringValue == "Reading…", "\(label)")
            case .normal:
                #expect(footer.name.stringValue == name && footer.count.stringValue == count, "\(label)")
                let row = try readFailedRow(shell, folder)
                #expect(row.countLabel.stringValue == (index.isMultiple(of: 2) ? "" : "5"), "\(label)")
                #expect(shell.searchButton.isEnabled && shell.sortButton.isEnabled, "\(label)")
                #expect(!shell.folderTree.showsZeroForUnknownCurrent && !shell.folderTree.showsDashForCurrent, "\(label)")
            }
            if mode != .normal {
                name = "n\(index)-\(step).png"; count = "\(step + 2) images"
                shell.setCurrentFile(name); shell.setSearchStatus(resultCount: step + 2, term: "")
            }
        }
    }
}
