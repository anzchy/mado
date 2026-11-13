import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

/// Owner decision C on #137 (2026-10-29): an empty folder session in the single-image viewer renders page 22's content
/// on the viewer surface, never the generic first-launch state.
@MainActor private func viewerStateHost() -> (NSWindow, ViewerStateHost) {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = ViewerStateHost(frame: frame)
    window.contentView?.addSubview(host)
    return (window, host)
}

private let viewerFolder = URL(fileURLWithPath: "/viewer/Trip")
private let viewerSubfolders = ["2024 冲绳", "手机备份", "扫描件"].map { viewerFolder.appendingPathComponent($0) }
private let genericHeading = "Drop a photo folder here"

@MainActor private func sameViews(_ a: [NSView], _ b: [NSView]) -> Bool {
    a.map(ObjectIdentifier.init) == b.map(ObjectIdentifier.init)
}

@Test(.timeLimit(.minutes(2))) @MainActor func viewerEmptyFolderRendersPage22Subfolders() {
    let (window, host) = viewerStateHost()
    defer { window.close() }
    host.setEmptyFolderPage(EmptyFolderPage(subfolders: viewerSubfolders, recents: [], includeSubfoldersAvailable: true))
    host.display(.emptyFolder)
    let page = host.emptyFolderView
    #expect(!host.isHidden && page.superview === host && !page.isHiddenOrHasHiddenAncestor)
    #expect(page.frame == host.bounds)
    #expect(page.heading.stringValue == "This level has no images, but has 3 subfolders")
    #expect(page.tiles.map(\.url) == viewerSubfolders)
    #expect(!page.primaryButton.isHiddenOrHasHiddenAncestor && !page.chooseButton.isHiddenOrHasHiddenAncestor)
    #expect(!host.textLines.contains(genericHeading))
    #expect(!host.buttons.contains { $0.identifier?.rawValue == "state.open" })
    #expect(sameViews(host.buttons, page.keyViews), "the viewer's Tab loop reaches page 22's controls")
    let refusing = host.buttons.filter { !$0.acceptsFirstResponder }
    #expect(refusing.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func viewerEmptyFolderRendersPage22RecentsAndBarePage() {
    let (window, host) = viewerStateHost()
    defer { window.close() }
    let now = Date(timeIntervalSince1970: 1_615_809_600)
    let recent = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/viewer/R"), displayName: "R",
                              openedAt: now.addingTimeInterval(-86_400))
    let row = EmptyFolderRecentRow(folder: recent, relativeTime: "yesterday")
    host.display(.emptyFolder)
    let page = host.emptyFolderView
    #expect(!page.isHiddenOrHasHiddenAncestor, "the page shows before its content arrives")
    #expect(page.heading.stringValue == "This folder has no images to browse yet")
    #expect(page.tiles.isEmpty && page.recentRows.isEmpty && page.recentsGroup.isHidden)
    #expect(!host.textLines.contains(genericHeading))
    host.setEmptyFolderPage(EmptyFolderPage(subfolders: [], recents: [row], includeSubfoldersAvailable: true))
    #expect(page.recentRows.map(\.folder) == [recent] && !page.recentsGroup.isHidden)
    #expect(page.primaryButton.isHidden && page.chooseButton.style == .secondary)
    #expect(sameViews(host.buttons, page.keyViews))
    host.setEmptyFolderPage(EmptyFolderPage(subfolders: viewerSubfolders, recents: [], includeSubfoldersAvailable: false))
    #expect(page.tiles.count == 3 && page.primaryButton.isHidden, "recursive already on hides the button")
    #expect(sameViews(host.buttons, page.keyViews), "updated in place without a status change")
}

@Test(.timeLimit(.minutes(2))) @MainActor func viewerPage22LeavesWithItsStatus() {
    let (window, host) = viewerStateHost()
    defer { window.close() }
    host.setEmptyFolderPage(EmptyFolderPage(subfolders: viewerSubfolders, recents: [], includeSubfoldersAvailable: true))
    host.display(.emptyFolder)
    host.display(.empty)
    #expect(host.emptyFolderView.superview == nil)
    #expect(host.textLines.first == genericHeading, "no folder session: the generic state")
    host.display(.emptyFolder)
    #expect(host.emptyFolderView.superview === host && !host.emptyFolderView.isHiddenOrHasHiddenAncestor)
    #expect(host.emptyFolderView.tiles.count == 3)
    host.display(.showing)
    #expect(host.isHidden)
    host.display(.emptyFolder)
    host.surface = .grid
    #expect(host.isHidden, "the grid surface shows its own page 22")
}

@Test(.timeLimit(.minutes(2))) @MainActor func viewerPage22ControlsReceiveClicks() throws {
    let (window, host) = viewerStateHost()
    defer { window.close() }
    host.setEmptyFolderPage(EmptyFolderPage(subfolders: viewerSubfolders, recents: [], includeSubfoldersAvailable: true))
    host.display(.emptyFolder)
    let page = host.emptyFolderView
    let tile = try #require(page.tiles.dropFirst().first)
    for control in [tile, page.primaryButton, page.chooseButton] as [NSView] {
        let point = host.superview!.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
        #expect(host.hitTest(point) === control)
    }
    #expect(host.hitTest(NSPoint(x: 4, y: 4))?.isDescendant(of: page) == true, "blank page area stays the drop target")
}
