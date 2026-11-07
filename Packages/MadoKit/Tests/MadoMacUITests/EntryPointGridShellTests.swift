import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private func expectComingSoonContentFits(_ button: NSButton) {
    let contentSize = button.cell?.cellSize ?? .zero
    #expect(contentSize.width <= button.frame.width + 0.01,
            "content width \(contentSize.width) exceeds frame \(button.frame)")
    #expect(contentSize.height <= button.frame.height + 0.01,
            "content height \(contentSize.height) exceeds frame \(button.frame)")
}

@Test @MainActor func issue215GridComingSoonEntriesAreVisibleDisabledAndUnfocusable() {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    shell.layoutSubtreeIfNeeded()
    let entries: [(EntryPoint, NSButton)] = [
        (.favorites, shell.favoritesButton),
        (.recents, shell.recentsButton),
        (.footerInfo, shell.infoButton),
    ]

    for (entry, button) in entries {
        #expect(entry.state == .comingSoon)
        #expect(button.superview != nil)
        #expect(!button.isHidden)
        #expect(!button.isEnabled)
        #expect(!button.acceptsFirstResponder)
        #expect(!button.canBecomeKeyView)
        #expect(button.action == nil)
        #expect(button.keyEquivalent.isEmpty)
        let marker = entry.accessibilityLabel(for: .preferred)
        #expect(button.toolTip?.contains(marker) == true)
        #expect(button.accessibilityLabel()?.contains(marker) == true)
        expectComingSoonContentFits(button)
    }
    #expect(shell.infoButton.title.isEmpty)
    #expect(shell.displayButton.title.isEmpty)
    #expect(shell.infoButton.image != nil)
    #expect(shell.displayButton.image != nil)
    // #114 (owner: 「两者都做，共用一组偏好」): the Display button is implemented, not coming soon.
    #expect(EntryPoint.footerDisplay.state == .implemented)
    #expect(shell.displayButton.isEnabled && shell.displayButton.acceptsFirstResponder && shell.displayButton.action != nil)
    #expect(shell.displayButton.accessibilityLabel()?.contains(EntryPoint.footerInfo.accessibilityLabel(for: .preferred)) == false)
    expectComingSoonContentFits(shell.displayButton)
}

@Test @MainActor func issue215ComingSoonLayoutFitsDesignAndNarrowWindowInBothLanguages() throws {
    _ = NSApplication.shared
    for width in [1280.0, 800.0, 480.0, 238.0] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let preferences = InMemoryDisplayPreferencesStore()
            let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 680),
                                      preferencesStore: preferences)
            shell.appearance = NSAppearance(named: appearance)
            shell.layoutSubtreeIfNeeded()
            let expectedWidth: CGFloat = width <= 480 ? 26 : 30
            let gap: CGFloat = width <= 800 ? 2 : 6
            let trailingInset: CGFloat = width <= 480 ? 7 : 12
            let controls = [shell.searchButton, shell.sortButton, shell.infoButton, shell.displayButton]
            for (index, control) in controls.enumerated() {
                #expect(control.frame.size == NSSize(width: expectedWidth, height: 28))
                #expect(control.frame.minX >= shell.toggleButton.frame.maxX)
                if index > 0 {
                    #expect(controls[index - 1].frame.maxX + gap == control.frame.minX)
                }
            }
            #expect(abs(shell.displayButton.frame.maxX - (width - trailingInset)) < 0.01)
            shell.setSearchStatus(resultCount: 4, term: "旅行")
            shell.layoutSubtreeIfNeeded()
            #expect(shell.searchStatus.isHidden == (width <= 480))
            if width > 480 { #expect(shell.searchStatus.frame.width >= 48) }
            shell.focusSearch()
            shell.layoutSubtreeIfNeeded()
            #expect(shell.searchStatus.isHidden == (width <= 480))
            if !shell.searchStatus.isHidden {
                #expect(shell.searchStatus.frame.width >= 48)
                #expect(shell.searchStatus.frame.maxX <= shell.searchField.frame.minX)
            }

            for sidebarWidth in [196, 160] {
                preferences.value.gridSidebarWidth = Double(sidebarWidth)
                shell.resizeSidebar(to: Double(sidebarWidth))
                for (_, titles) in [
                    ("en", ["Personal Favorites", "Recently Viewed"]),
                    ("zh-Hans", ["个人收藏", "最近查看"]),
                ] {
                    for (button, title) in zip([shell.favoritesButton, shell.recentsButton], titles) {
                        button.title = title
                        expectComingSoonContentFits(button)
                    }
                }
                #expect(shell.favoritesButton.frame.height >= 32)
                #expect(shell.recentsButton.frame.height >= 32)
            }
        }
    }
}

@Test @MainActor func issue215EveryVisibleComingSoonControlIsDeclaredInModel() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    shell.layoutSubtreeIfNeeded()
    let controls = (shell.footer.subviews + shell.sidebar.subviews).compactMap { $0 as? NSButton }.filter {
        !$0.isEnabled && ($0.accessibilityLabel()?.contains("Coming Soon") == true
            || $0.accessibilityLabel()?.contains("即将推出") == true)
    }
    #expect(Set(controls.compactMap { $0.accessibilityIdentifier() }) == [
        "grid.favorites.row", "grid.recents.row", "grid.info.button",
    ])
    for control in controls {
        let entry = try #require(shell.entryPoint(for: control),
                                 "Undeclared coming-soon control: \(control.accessibilityIdentifier())")
        #expect(entry.state == .comingSoon)
        let marker = entry.accessibilityLabel(for: .preferred)
        #expect(control.toolTip?.contains(marker) == true)
        #expect(control.accessibilityLabel()?.contains(marker) == true)
    }
}
