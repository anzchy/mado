import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@MainActor private struct PageKeyScene {
    let grid: GridBrowserView
    let window: NSWindow
    let count: Int

    init(count: Int = 120, width: CGFloat = 1200, height: CGFloat = 600) {
        _ = NSApplication.shared
        self.count = count
        let folder = URL(fileURLWithPath: "/tmp/picsee-page-keys")
        let rootID = AccessRootID(rawValue: UUID())
        let root = ItemIdentityRoot(id: rootID, url: folder)
        let entries = (0..<count).map {
            FolderEntry(url: folder.appendingPathComponent(String(format: "%03d.jpg", $0)), root: root)
        }
        grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid
        scroll.automaticallyAdjustsContentInsets = false
        grid.display(FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
            entries: entries, isComplete: true), selectedItemID: nil)
        grid.activate()
        grid.layoutSubtreeIfNeeded()
    }

    var scroll: NSScrollView { grid.collectionView.enclosingScrollView! }
    var index: Int? { grid.currentItemID.flatMap(grid.index(for:)) }
    var visible: NSRect {
        var rect = scroll.contentView.documentVisibleRect
        rect.origin.y += scroll.contentInsets.top
        rect.size.height -= scroll.contentInsets.top + scroll.contentInsets.bottom
        return rect
    }
    var columns: Int {
        guard count > 0 else { return 1 }
        let y = grid.collectionView.frameForItem(at: 0).minY
        return (0..<count).prefix { grid.collectionView.frameForItem(at: $0).minY == y }.count
    }
    var page: Int {
        let layout = grid.collectionView.collectionViewLayout as! NSCollectionViewFlowLayout
        let height = grid.collectionView.frameForItem(at: 0).height
        // Independently count how many complete cells fit, including only gaps between rows.
        var rows = 1
        while CGFloat(rows + 1) * height + CGFloat(rows) * layout.minimumLineSpacing <= visible.height {
            rows += 1
        }
        return rows * columns
    }
    func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let chars: [UInt16: String] = [115: "\u{F729}", 119: "\u{F72B}",
            116: "\u{F72C}", 121: "\u{F72D}", 124: "\u{F703}"]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: chars[code]!, charactersIgnoringModifiers: chars[code]!,
            isARepeat: false, keyCode: code)!
    }
    func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        window.firstResponder?.keyDown(with: event(code, flags))
    }
    func reset(_ index: Int, selected: [Int] = []) {
        var selection = BrowserSelection()
        for item in selected {
            selection.click(grid.itemID(at: item)!, modifier: .command, in: grid.displayedItemIDs)
        }
        selection.focus(grid.itemID(at: index)!, in: grid.displayedItemIDs)
        grid.synchronizeSelection(selection)
        grid.activate(currentItemID: grid.itemID(at: index))
    }
    func target(_ code: UInt16, from: Int) -> Int {
        switch code {
        case 115: return 0
        case 119: return count - 1
        case 116: return max(0, from - page)
        default: return min(count - 1, from + page)
        }
    }
    func expectSelected(_ indices: Set<Int>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(grid.selection.selectedItemIDs == Set(indices.compactMap(grid.itemID(at:))), sourceLocation: sourceLocation)
        #expect(grid.collectionView.selectionIndexPaths == Set(indices.map { IndexPath(item: $0, section: 0) }),
            sourceLocation: sourceLocation)
    }
    func expectRevealed(sourceLocation: SourceLocation = #_sourceLocation) {
        if let index {
            let tile = grid.collectionView.frameForItem(at: index)
            if tile.height <= visible.height {
                #expect(visible.contains(tile), "\(tile) outside \(visible)", sourceLocation: sourceLocation)
            }
        }
    }
}

@Test @MainActor func issue453PageAndEdgeKeysMoveSelectAndReveal() {
    let scene = PageKeyScene()
    for code: UInt16 in [121, 116, 115, 119] {
        scene.reset(40, selected: [40])
        let target = scene.target(code, from: 40)
        scene.press(code)
        #expect(scene.index == target, "key \(code)")
        scene.expectSelected([target])
        scene.expectRevealed()
        #expect(scene.window.firstResponder === scene.grid.collectionView)
    }
}

@Test @MainActor func issue453PageSizeTracksLiveGeometryAndInsets() {
    let scene = PageKeyScene(count: 240)
    for width: CGFloat in [480, 720, 1200] {
        scene.window.setContentSize(NSSize(width: width, height: 600))
        for names in [false, true] {
            scene.grid.displayOptions = GridDisplayOptions(thumbnailSize: names ? 140 : 280, showFileNames: names)
            scene.grid.layoutSubtreeIfNeeded()
            let layout = scene.grid.collectionView.collectionViewLayout as! NSCollectionViewFlowLayout
            let cell = layout.itemSize.height, gap = layout.minimumLineSpacing
            for usableHeight in [cell / 2, cell, 2 * cell + gap - 0.25, 2 * cell + gap, 2 * cell + gap + 0.25] {
                for inset: CGFloat in [0, 40] {
                    scene.scroll.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
                    scene.window.setContentSize(NSSize(width: width, height: usableHeight + 2 * inset))
                    scene.grid.layoutSubtreeIfNeeded()
                    scene.reset(100, selected: [100])
                    let step = scene.page
                    scene.press(121)
                    #expect(scene.index == 100 + step)
                    scene.expectRevealed()
                    scene.press(116)
                    #expect(scene.index == 100)
                    scene.expectRevealed()
                }
            }
        }
    }
}

@Test @MainActor func issue453EdgesRevealCurrentAndRepeatWithoutScrolling() {
    let scene = PageKeyScene()
    scene.scroll.contentInsets = NSEdgeInsets(top: 24, left: 0, bottom: 40, right: 0)
    for (code, endpoint): (UInt16, Int) in [(115, 0), (119, 119)] {
        scene.reset(endpoint, selected: [endpoint])
        scene.grid.restoreContentOffset(NSPoint(x: 0, y: endpoint == 0 ? 900 : 0))
        scene.press(code)
        scene.expectRevealed()
        let revealed = scene.grid.contentOffset
        scene.press(code)
        #expect(scene.grid.contentOffset == revealed)
        scene.expectSelected([endpoint])
    }
    scene.reset(0, selected: [0])
    scene.grid.restoreContentOffset(.zero)
    let offset = scene.grid.contentOffset
    scene.press(121)
    scene.press(116)
    scene.expectRevealed()
    scene.press(115)
    let home = scene.grid.contentOffset
    scene.press(115)
    #expect(scene.grid.contentOffset == home)
    #expect(offset.y == 0)
}

@Test @MainActor func issue453ShiftAndCommandPreserveArrowSelectionSemantics() {
    let scene = PageKeyScene()
    for flags: NSEvent.ModifierFlags in [.shift, .command] {
        scene.reset(40, selected: [2, 40, 70])
        scene.press(124, flags)
        scene.expectSelected([2, 40, 70])
        #expect(scene.index == 41)
        for code: UInt16 in [121, 116, 115, 119] {
            scene.reset(40, selected: [2, 40, 70])
            let target = scene.target(code, from: 40)
            scene.press(code, flags)
            #expect(scene.index == target)
            scene.expectSelected([2, 40, 70])
            scene.expectRevealed()
        }
    }
}

@Test @MainActor func issue453EmptySingletonAndPartialRowsClamp() {
    let empty = PageKeyScene(count: 0)
    let offset = empty.grid.contentOffset
    for flags: NSEvent.ModifierFlags in [[], .shift] {
        for code: UInt16 in [121, 116, 115, 119] {
            empty.press(code, flags)
            #expect(empty.index == nil)
            empty.expectSelected([])
            #expect(empty.grid.contentOffset == offset)
        }
    }
    let partial = PageKeyScene(count: 23)
    #expect(23 % partial.columns != 0)
    for flags: NSEvent.ModifierFlags in [[], .shift] {
        partial.reset(0)
        for _ in 0..<12 { partial.press(121, flags) }
        #expect(partial.index == 22)
        partial.expectRevealed()
        for _ in 0..<12 { partial.press(116, flags) }
        #expect(partial.index == 0)
        partial.expectRevealed()
    }
}

/// Exhaustive finite domain; S4 bounds plus S5 repeated-edge/inverse invariants, no random/shrinking claim.
@Test @MainActor func issue453BoundedMovementLaws() {
    for width: CGFloat in [480, 1200] {
        for count in 1...9 {
            let scene = PageKeyScene(count: count, width: width, height: 240)
            for start in 0..<count {
                for flags: NSEvent.ModifierFlags in [[], .shift] {
                    for code: UInt16 in [115, 119, 116, 121] {
                        scene.reset(start, selected: [start])
                        let target = scene.target(code, from: start)
                        scene.press(code, flags)
                        #expect(scene.index == target)
                        #expect((0..<count).contains(scene.index!))
                        scene.expectSelected(flags.isEmpty ? [target] : [start])
                        if code == 115 || code == 119 {
                            let offset = scene.grid.contentOffset
                            scene.press(code, flags)
                            #expect(scene.index == target)
                            #expect(scene.grid.contentOffset == offset)
                        } else if start + scene.page < count && code == 121 {
                            scene.press(116, flags)
                            #expect(scene.index == start)
                        }
                    }
                }
            }
        }
    }
}

@MainActor private final class PageOtherResponder: NSView {
    var received: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
}

@Test @MainActor func issue453TextEditorAndOtherResponderKeepTheirKeys() throws {
    let scene = PageKeyScene()
    scene.reset(40, selected: [40])
    let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    search.stringValue = "search text"
    scene.grid.addSubview(search)
    search.selectText(nil)
    let editor = try #require(search.currentEditor())
    #expect(scene.window.firstResponder === editor)
    let selection = scene.grid.selection, offset = scene.grid.contentOffset
    for code: UInt16 in [115, 119, 116, 121] {
        scene.press(code)
        #expect(scene.window.firstResponder === editor)
        #expect(scene.grid.selection == selection)
        #expect(scene.grid.contentOffset == offset)
        #expect(search.stringValue == "search text")
    }
    let other = PageOtherResponder(frame: .zero)
    scene.grid.addSubview(other)
    #expect(scene.window.makeFirstResponder(other))
    for code: UInt16 in [115, 119, 116, 121] {
        scene.press(code)
        #expect(scene.window.firstResponder === other)
        #expect(scene.grid.selection == selection)
        #expect(scene.grid.contentOffset == offset)
    }
    #expect(other.received == [115, 119, 116, 121])
}

@Test @MainActor func issue453AlreadyCurrentUnselectedEdgesStillSelect() {
    for count in [1, 120] {
        let scene = PageKeyScene(count: count)
        for (code, endpoint): (UInt16, Int) in [(115, 0), (119, count - 1)] {
            for flags: NSEvent.ModifierFlags in [[], .shift] {
                scene.reset(endpoint)
                scene.press(code, flags)
                #expect(scene.index == endpoint)
                scene.expectSelected(flags.isEmpty ? [endpoint] : [])
                scene.expectRevealed()
            }
        }
    }
}

/// A displayed snapshot can receive native focus before activate() establishes Current Item.
@Test @MainActor func issue453NativeFocusWithoutCurrentStartsPageAndEdgeMovesAtZero() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-page-keys-no-current")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entries = (0..<120).map {
        FolderEntry(url: folder.appendingPathComponent(String(format: "%03d.jpg", $0)), root: root)
    }
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: entries, isComplete: true)
    let characters: [UInt16: String] = [115: "\u{F729}", 119: "\u{F72B}",
        116: "\u{F72C}", 121: "\u{F72D}"]
    for flags: NSEvent.ModifierFlags in [[], .shift] {
        for code: UInt16 in [115, 119, 116, 121] {
            let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
            let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = grid
            grid.display(snapshot, selectedItemID: nil)
            grid.layoutSubtreeIfNeeded()
            #expect(grid.currentItemID == nil)
            #expect(window.makeFirstResponder(grid.collectionView))
            #expect(grid.currentItemID == nil, "Native focus does not call activate()")
            let scroll = grid.collectionView.enclosingScrollView!
            let insets = scroll.contentInsets
            var visible = scroll.contentView.documentVisibleRect
            visible.origin.y += insets.top
            visible.size.height -= insets.top + insets.bottom
            let first = grid.collectionView.frameForItem(at: 0)
            let columns = (0..<entries.count).prefix { grid.collectionView.frameForItem(at: $0).minY == first.minY }.count
            let layout = grid.collectionView.collectionViewLayout as! NSCollectionViewFlowLayout
            var rows = 1
            while CGFloat(rows + 1) * first.height + CGFloat(rows) * layout.minimumLineSpacing <= visible.height {
                rows += 1
            }
            let target = code == 119 ? entries.count - 1 : code == 121 ? rows * columns : 0
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters[code]!, charactersIgnoringModifiers: characters[code]!,
                isARepeat: false, keyCode: code)!
            window.firstResponder?.keyDown(with: event)
            #expect(grid.currentItemID == entries[target].itemID)
            #expect(grid.selection.selectedItemIDs == (flags.isEmpty ? [entries[target].itemID] : []))
            #expect(grid.collectionView.selectionIndexPaths == (flags.isEmpty ? [IndexPath(item: target, section: 0)] : []))
            visible = scroll.contentView.documentVisibleRect
            visible.origin.y += insets.top
            visible.size.height -= insets.top + insets.bottom
            #expect(visible.contains(grid.collectionView.frameForItem(at: target)))
            #expect(window.firstResponder === grid.collectionView)
        }
    }
}

@Test @MainActor func issue453Fix1ClampedPageKeysKeepMultiSelectionLikeArrows() {
    let scene = PageKeyScene()
    for (page, arrow, endpoint, selected): (UInt16, UInt16, Int, Set<Int>) in [
        (121, 125, 119, [2, 119]), (116, 126, 0, [0, 2]),
    ] {
        scene.reset(endpoint, selected: selected.sorted())
        scene.grid.restoreContentOffset(NSPoint(x: 0, y: endpoint == 0 ? 900 : 0))
        let selection = scene.grid.selection
        let nativeSelection = scene.grid.collectionView.selectionIndexPaths
        let current = scene.grid.currentItemID, offset = scene.grid.contentOffset
        let character = arrow == 125 ? "\u{F701}" : "\u{F700}"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: scene.window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: arrow)!
        for _ in 0..<2 {
            scene.grid.collectionView.keyDown(with: event)
            #expect(scene.grid.selection == selection)
            #expect(scene.grid.contentOffset == offset)
            scene.press(page)
            #expect(scene.grid.currentItemID == current)
            #expect(scene.grid.selection == selection, "clamped page key must preserve the picked set like its arrow")
            #expect(scene.grid.collectionView.selectionIndexPaths == nativeSelection)
            #expect(scene.grid.contentOffset == offset, "a clamped page key must not reveal an offscreen current item")
        }
    }
}

@Test @MainActor func issue453Fix1HomeEndExplicitlySelectAndRevealCurrentEndpoint() {
    let scene = PageKeyScene()
    for (key, endpoint, selected): (UInt16, Int, Set<Int>) in [(115, 0, [0, 2]), (119, 119, [2, 119])] {
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            scene.reset(endpoint, selected: selected.sorted())
            scene.grid.restoreContentOffset(NSPoint(x: 0, y: endpoint == 0 ? 900 : 0))
            scene.press(key, flags)
            #expect(scene.index == endpoint)
            scene.expectSelected(flags.isEmpty ? [endpoint] : selected)
            scene.expectRevealed()
            let offset = scene.grid.contentOffset
            scene.press(key, flags)
            scene.expectSelected(flags.isEmpty ? [endpoint] : selected)
            #expect(scene.grid.contentOffset == offset)
        }
    }
}
