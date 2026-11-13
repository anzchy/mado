import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func issue604FailureProjectionKeepsSiblingDepthAndCountOwnership() throws {
    _ = NSApplication.shared
    let parent = URL(fileURLWithPath: "/tmp/Parent")
    let locked = parent.appendingPathComponent("Locked")
    let readable = parent.appendingPathComponent("Readable")
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 600))
    tree.show(current: .init(url: parent), parent: nil,
        children: [.init(url: locked), .init(url: readable, count: 2)])
    tree.showsDashForCurrent = true
    tree.show(current: .init(url: locked, count: 3), parent: .init(url: parent, count: 1), children: [],
        siblings: [.init(url: locked, count: 3), .init(url: readable, count: 2)])
    #expect(tree.rows.map(\.folderURL) == [parent, locked, readable])
    #expect(tree.rows.map(\.depth) == [0, 1, 1])
    #expect(tree.rows.map(\.current) == [false, true, false])
    #expect(tree.rows[1].countLabel.stringValue == "—")
    #expect(!tree.guide.isHidden)
    tree.updateCount(7, for: readable)
    #expect(tree.siblings.map(\.count) == [7])
    #expect(tree.rows[2].countLabel.stringValue == "7")
    tree.showsDashForCurrent = false
    tree.readingFolderURL = locked
    #expect(tree.rows[1].countLabel.isHidden)
    #expect(tree.rows[2].countLabel.stringValue == "7")
    tree.updateCount(8, for: locked)
    #expect(tree.rows[1].countLabel.isHidden)
    tree.readingFolderURL = nil
    #expect(tree.rows[1].countLabel.stringValue == "8")
    tree.show(current: .init(url: locked, count: 3), parent: .init(url: parent), children: [])
    #expect(tree.rows.map(\.folderURL) == [parent, locked])
    #expect(tree.siblings.isEmpty)
    #expect(tree.rows[1].countLabel.stringValue == "3")
    tree.clear()
    #expect(tree.rows.isEmpty && tree.siblings.isEmpty)
    tree.show(current: .init(url: locked, accessLossCause: .accessExpired), parent: .init(url: parent),
        children: [], siblings: [.init(url: readable)])
    #expect(tree.siblings.isEmpty)
    #expect(tree.rows.map(\.folderURL) == [parent, locked])
    tree.show(current: .init(url: parent), parent: nil, children: [], siblings: [.init(url: readable)])
    #expect(tree.siblings.isEmpty)
}
