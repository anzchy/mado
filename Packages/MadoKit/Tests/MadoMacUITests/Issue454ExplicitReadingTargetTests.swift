import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private func target454Shell() -> GridShellView {
    _ = NSApplication.shared
    return GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
        preferencesStore: InMemoryDisplayPreferencesStore())
}

@MainActor private func target454Expect(_ shell: GridShellView, _ folder: URL, count: Int?) throws {
    let row = try #require(shell.folderTree.rows.first { $0.folderURL == folder })
    #expect(row.countLabel.stringValue == (count.map(String.init) ?? ""))
    #expect(row.countLabel.isHidden == (count == nil))
    let images = count.map { String(format: String(localized: "%lld images"), Int64($0)) }
    #expect(row.accessibilityLabel() == (images.map { "\(folder.lastPathComponent), \($0)" } ?? folder.lastPathComponent))
    shell.layoutSubtreeIfNeeded()
    row.layoutSubtreeIfNeeded()
    if count != nil { #expect(row.countLabel.frame.width > 0) }
}

/// S5: changing the selected role cannot transfer a read's mask to another folder.
@Test @MainActor func issue454ExplicitTargetPreservesNonTargetCountsAcrossRoleChanges() throws {
    let shell = target454Shell()
    let parent = URL(fileURLWithPath: "/target454/Parent")
    let current = parent.appendingPathComponent("Current")
    let child = current.appendingPathComponent("Child")
    shell.showFolderTree(current: .init(url: current, count: 3), parent: .init(url: parent, count: 7),
        children: [.init(url: child, count: 2)])
    shell.readingFolderURL = child
    shell.setReadingStatus(true)
    try target454Expect(shell, parent, count: 7)
    try target454Expect(shell, current, count: 3)
    try target454Expect(shell, child, count: nil)
    shell.showFolderTree(current: .init(url: child, count: 2), parent: .init(url: current, count: 3),
        children: [.init(url: parent, count: 7)])
    try target454Expect(shell, child, count: nil)
    try target454Expect(shell, current, count: 3)
    try target454Expect(shell, parent, count: 7)
    shell.readingFolderURL = current
    try target454Expect(shell, current, count: nil)
    try target454Expect(shell, child, count: 2)
    try target454Expect(shell, parent, count: 7)
    shell.setReadingStatus(false)
    try target454Expect(shell, current, count: 3)
    try target454Expect(shell, child, count: 2)
    #expect(shell.readingFolderURL == nil)
}

/// S5: masking retains the latest model value through callbacks and rebuilt rows.
@Test @MainActor func issue454ExplicitTargetRoundTripsUnknownZeroPositiveAndLateCounts() throws {
    let folder = URL(fileURLWithPath: "/target454/Reading")
    let sibling = URL(fileURLWithPath: "/target454/Sibling")
    for initial in [nil, 0, 12] as [Int?] {
        for latest in [nil, 0, 9] as [Int?] {
            let shell = target454Shell()
            shell.readingFolderURL = folder
            shell.setReadingStatus(true)
            shell.showFolderTree(current: .init(url: folder, count: initial), parent: nil,
                children: [.init(url: sibling, count: 2)])
            try target454Expect(shell, folder, count: nil)
            shell.updateFolderCount(latest, for: folder)
            try target454Expect(shell, folder, count: nil)
            try target454Expect(shell, sibling, count: 2)
            shell.showFolderTree(current: .init(url: folder, count: latest), parent: nil,
                children: [.init(url: sibling, count: 2)])
            try target454Expect(shell, folder, count: nil)
            try target454Expect(shell, sibling, count: 2)
            shell.setReadingStatus(false)
            try target454Expect(shell, folder, count: latest)
            try target454Expect(shell, sibling, count: 2)
        }
    }
}

/// S5: failure clears the old target; Retry supplies the failed folder again.
@Test @MainActor func issue454ExplicitTargetFailureRetryAndCompletionKeepPrecedence() throws {
    let folder = URL(fileURLWithPath: "/target454/Failed")
    let other = URL(fileURLWithPath: "/target454/Other")
    for initial in [nil, 0, 3] as [Int?] {
        let shell = target454Shell()
        shell.showFolderTree(current: .init(url: folder, count: initial), parent: .init(url: other, count: 7), children: [])
        shell.readingFolderURL = folder
        shell.setReadingStatus(true)
        try target454Expect(shell, folder, count: nil)
        shell.setReadFailedStatus(true)
        #expect(shell.readingFolderURL == nil)
        let failed = try #require(shell.folderTree.rows.first { $0.current })
        #expect(failed.countLabel.stringValue == "—")
        #expect(failed.accessibilityLabel() == "\(folder.lastPathComponent), \(String(localized: "Read incomplete"))")
        shell.updateFolderCount(9, for: folder)
        #expect(failed.countLabel.stringValue == "—")
        try target454Expect(shell, other, count: 7)
        shell.readingFolderURL = folder
        shell.setReadingStatus(true)
        try target454Expect(shell, folder, count: nil)
        try target454Expect(shell, other, count: 7)
        shell.setReadingStatus(false)
        try target454Expect(shell, folder, count: 9)
    }
}

/// The independently counted sidebar is not overwritten by the main projection's total.
@Test @MainActor func issue454ExplicitTargetKeepsSidebarCountProvenance() throws {
    let shell = target454Shell()
    let grid = GridBrowserView(frame: shell.mainFrame)
    shell.mainContent.addSubview(grid)
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView(), shell: shell)
    let folder = URL(fileURLWithPath: "/target454/Counted")
    let child = folder.appendingPathComponent("Child")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    for total in [3, 0] {
        shell.showFolderTree(current: .init(url: folder, count: 9), parent: nil,
            children: [.init(url: child, count: 2)])
        shell.readingFolderURL = folder
        presentation.showGrid(reading: true)
        try target454Expect(shell, folder, count: nil)
        try target454Expect(shell, child, count: 2)
        let entries = (0..<total).map { FolderEntry(url: folder.appendingPathComponent("\($0).png"), root: root) }
        let snapshot = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: UInt64(total + 1)),
            entries: entries, isComplete: true)
        presentation.showCompletedGrid(snapshot, selection: BrowserSelection(), currentItemID: nil, offset: nil)
        try target454Expect(shell, folder, count: 9)
        try target454Expect(shell, child, count: 2)
        func field(in view: NSView) -> NSTextField? {
            if let text = view as? NSTextField, text.accessibilityIdentifier() == "grid.folder-count" { return text }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        #expect(field(in: shell)?.stringValue == String(format: String(localized: "%lld images"), Int64(total)))
    }
}
