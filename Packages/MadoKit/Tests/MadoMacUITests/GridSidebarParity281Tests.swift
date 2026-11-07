import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private func issue281SidebarView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let match = issue281SidebarView(id, in: child) { return match }
    }
    return nil
}

@Test @MainActor func issue281SidebarRowsAndAddFolderMatchPinnedFrames() throws {
    let design = try PinnedDesign.page("grid-light")
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    let root = URL(fileURLWithPath: "/tmp/Images")
    let children = [
        GridSidebarFolder(url: root.appendingPathComponent(String(repeating: "长目录名", count: 20)), count: 12345),
        GridSidebarFolder(url: root.appendingPathComponent("English folder with a long name"), count: 7),
        GridSidebarFolder(url: root.appendingPathComponent("Third"), count: 1),
    ]
    tree.show(current: GridSidebarFolder(url: root, count: 12), parent: nil, children: children)
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows.count == 4)
    // grid-light.html: .ds-nav-row is min-height 32px; child rows have no extra bottom gap.
    #expect(tree.rows[1].frame.minY - tree.rows[2].frame.minY == 32)
    #expect(tree.rows[2].frame.minY - tree.rows[3].frame.minY == 32)
    #expect(tree.rows[1].countLabel.stringValue == "12345")
    #expect(tree.rows[1].nameLabel.frame.maxX <= tree.rows[1].countLabel.frame.minX)
    #expect(tree.rows[1].nameLabel.lineBreakMode == .byTruncatingTail)

    let plus = try #require(issue281SidebarView("grid.sidebar.add-folder-plus", in: tree) as? NSButton)
    #expect(plus.frame.minX > tree.heading.frame.minX)
    #expect(plus.frame.maxX <= tree.bounds.maxX)
    #expect(plus.isAccessibilityElement())
    #expect(plus.accessibilityLabel() == "Add Folder · Coming Soon")
    #expect(!plus.isEnabled)
    #expect(plus.refusesFirstResponder)
    let add = try #require(issue281SidebarView("grid.sidebar.add-folder", in: tree) as? NSButton)
    // grid-light.html: .add-folder has margin 12px 4px 0, height 30px, dashed 1px border and control radius.
    #expect(add.frame.height == 30)
    #expect(add.frame.minX == 16)
    #expect(add.frame.maxX == 179)
    #expect(tree.rows[3].frame.minY - add.frame.maxY == 12)
    #expect(add.title == "Add Folder")
    #expect(Double(add.layer?.cornerRadius ?? 0) == DesignMetrics.radii["control"]!)
    let dash = try #require(add.layer?.sublayers?.first { ($0 as? CAShapeLayer)?.lineDashPattern != nil } as? CAShapeLayer)
    #expect(dash.lineWidth == 1)
    #expect(add.isEnabled == false)
    #expect(add.refusesFirstResponder)
    let border = try #require(dash.strokeColor)
    let actual = try #require(NSColor(cgColor: border)?.usingColorSpace(.sRGB))
    let expected = try design.color(":root", "--color-border", viewport: 1280)
    #expect(abs(actual.redComponent - expected.red) < 0.01)
    #expect(abs(actual.greenComponent - expected.green) < 0.01)
    #expect(abs(actual.blueComponent - expected.blue) < 0.01)
}

@Test @MainActor func issue281SidebarDividerMatchesPinnedEdgeInLightAndDark() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
            preferencesStore: InMemoryDisplayPreferencesStore())
        shell.appearance = NSAppearance(named: appearance)
        shell.layoutSubtreeIfNeeded()
        let divider = try #require(issue281SidebarView("grid.sidebar.divider", in: shell))
        #expect(divider.frame.minX == 195)
        #expect(divider.frame.width == 1)
        #expect(divider.frame.height == shell.sidebar.frame.height)
        #expect(divider.layer?.backgroundColor != nil)
    }
}

@Test @MainActor func issue281AddFolderUsesSidebarContentBoxAtResponsiveWidths() throws {
    for (width, padding) in [(1280.0, 12.0), (1051.0, 12.0), (1050.0, 8.0), (720.0, 8.0), (480.0, 8.0)] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 772),
            preferencesStore: InMemoryDisplayPreferencesStore())
        shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/tmp/Images")), parent: nil, children: [])
        shell.layoutSubtreeIfNeeded()
        let add = try #require(issue281SidebarView("grid.sidebar.add-folder", in: shell))
        let frame = shell.convert(add.bounds, from: add)
        // grid-light.html: .sidebar has 12px padding (8px at max-width:1050), 1px border, then .add-folder margin 4px.
        #expect(abs(frame.minX - (padding + 4)) <= 1, "add-folder left at \(width)")
        #expect(abs(frame.maxX - (shell.sidebar.frame.maxX - padding - 1 - 4)) <= 1, "add-folder right at \(width)")
    }
}
