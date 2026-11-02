import AppKit
import Testing
import PicseeApplication
@testable import PicseeMacUI

/// #332: the footer status on page 26 (Lost Access, `— 无法访问` for every cause) and page 22 (empty folder, `— 0 张图片`).
private let lostEmptyDash = "\u{2014}"
private let lostEmptyCauses: [AccessLossCause] = [.diskNotConnected, .notFound, .accessExpired, .unknown]
private let lostEmptyFolderURL = URL(fileURLWithPath: "/lost-empty/待整理")
private let lostEmptyParentURL = URL(fileURLWithPath: "/lost-empty")
private let lostEmptyChildURL = lostEmptyFolderURL.appendingPathComponent("B")
private let lostEmptyNow = Date(timeIntervalSince1970: 0)

@MainActor private func lostEmptyShell(width: CGFloat = 1280, height: CGFloat = 772) -> (NSWindow, GridShellView) {
    _ = NSApplication.shared
    let size = NSSize(width: width, height: height)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let shell = GridShellView(frame: NSRect(origin: .zero, size: size), preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    lostEmptyShowTree(shell, cause: nil, count: 3)
    shell.layoutSubtreeIfNeeded()
    return (window, shell)
}

@MainActor private func lostEmptyShowTree(_ shell: GridShellView, cause: AccessLossCause?, count: Int? = nil,
                                          parentCause: AccessLossCause? = nil, childCause: AccessLossCause? = nil) {
    shell.showFolderTree(current: GridSidebarFolder(url: lostEmptyFolderURL, count: count, accessLossCause: cause),
                         parent: GridSidebarFolder(url: lostEmptyParentURL, accessLossCause: parentCause),
                         children: [GridSidebarFolder(url: lostEmptyChildURL, count: 4, accessLossCause: childCause)])
}

/// CanvasWindowController.handleAccessLoss / showWaitingAccessState, in their order.
@MainActor private func lostEmptyLose(_ shell: GridShellView, _ cause: AccessLossCause) {
    lostEmptyShowTree(shell, cause: cause)
    shell.setSearchTerm("")
    shell.setReadingStatus(false)
}

@MainActor private func lostEmptyEnterEmpty(_ shell: GridShellView) {
    shell.setSearchStatus(resultCount: 0, term: "")
    shell.setEmptyFolderState(true, recents: [], now: lostEmptyNow)
    shell.setReadingStatus(false)
}

@MainActor private func lostEmptyFind(_ id: String, in view: NSView) -> NSTextField? {
    if view.accessibilityIdentifier() == id, let field = view as? NSTextField { return field }
    return view.subviews.lazy.compactMap { lostEmptyFind(id, in: $0) }.first
}

@MainActor private func lostEmptyFooter(_ shell: GridShellView) throws -> (name: NSTextField, count: NSTextField) {
    shell.layoutSubtreeIfNeeded()
    return (try #require(lostEmptyFind("grid.current-file-status", in: shell)),
            try #require(lostEmptyFind("grid.folder-count", in: shell)))
}

/// Shown, with this exact text, in a frame wide enough to draw it untruncated.
@MainActor private func lostEmptySlot(_ field: NSTextField, _ text: String, _ label: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(field.stringValue == text, "\(label): \(field.stringValue)", sourceLocation: sourceLocation)
    #expect(!field.isHidden, "\(label): hidden", sourceLocation: sourceLocation)
    #expect(field.frame.width >= ceil(field.cell?.cellSize.width ?? .infinity),
            "\(label): width \(field.frame.width)", sourceLocation: sourceLocation)
}

@MainActor private func lostEmptyQuiet(_ field: NSTextField, _ label: String,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(field.isHidden || field.stringValue.isEmpty, "\(label): \(field.stringValue)", sourceLocation: sourceLocation)
}

@MainActor private func lostEmptyExpectLost(_ shell: GridShellView, _ label: String,
                                            sourceLocation: SourceLocation = #_sourceLocation) throws {
    let footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, lostEmptyDash, "\(label) name", sourceLocation: sourceLocation)
    lostEmptySlot(footer.count, "Unavailable", "\(label) count", sourceLocation: sourceLocation)
    #expect(footer.count.stringValue == String(localized: "Unavailable"), "\(label)", sourceLocation: sourceLocation)
}

private let lostEmptySizes: [(Int, Int)] = [(1280, 772), (800, 680)]

@Test(arguments: lostEmptyCauses, lostEmptySizes)
@MainActor func lostAccessFooterShowsDashAndUnavailable(cause: AccessLossCause, size: (Int, Int)) throws {
    let (window, shell) = lostEmptyShell(width: CGFloat(size.0), height: CGFloat(size.1))
    defer { window.close() }
    shell.setFooterActionsEnabled(true)
    shell.setCurrentFile("img1.png")
    shell.setSearchStatus(resultCount: 3, term: "")
    let searchBefore = shell.searchButton.isEnabled, sortBefore = shell.sortButton.isEnabled
    lostEmptyLose(shell, cause)
    for toggles in 0...2 {
        if toggles > 0 { shell.toggleSidebar() }
        try lostEmptyExpectLost(shell, "\(cause) \(size) toggles \(toggles)")
    }
    #expect(shell.searchButton.isEnabled == searchBefore && shell.sortButton.isEnabled == sortBefore)
}

@Test(arguments: [AccessLossCause.notFound, .accessExpired])
@MainActor func lostAccessIgnoresStaleFileAndCount(cause: AccessLossCause) throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    shell.setCurrentFile("img1.png")
    shell.setSearchStatus(resultCount: 3, term: "")
    lostEmptyLose(shell, cause)
    shell.setCurrentFile("late.png")
    try lostEmptyExpectLost(shell, "late file")
    shell.setSearchStatus(resultCount: 9, term: "")
    try lostEmptyExpectLost(shell, "late count")
    let term = "a-very-long-search-term-that-would-truncate-a-summary-in-the-footer-status-slot"
    shell.setSearchStatus(resultCount: 2, term: term)
    try lostEmptyExpectLost(shell, "late search summary")
    shell.toggleSidebar()
    try lostEmptyExpectLost(shell, "after toggle")
    lostEmptyShowTree(shell, cause: nil, count: 9)
    var footer = try lostEmptyFooter(shell)
    #expect(footer.name.stringValue == "late.png" && !footer.name.isHidden)
    #expect(footer.count.stringValue == String(format: String(localized: "Search: %@ · %lld results"), term, 2))
    #expect(!footer.count.isHidden)
    // CanvasWindowController.updateGridSearch resets the term to "" while page 26 is up.
    lostEmptyShowTree(shell, cause: cause)
    shell.setSearchTerm("")
    #expect(shell.searchStatus.stringValue == "Unavailable" && !shell.searchStatus.isHidden, "late empty term, no layout")
    try lostEmptyExpectLost(shell, "late empty term")
    lostEmptyShowTree(shell, cause: nil, count: 9)
    footer = try lostEmptyFooter(shell)
    #expect(footer.name.stringValue == "late.png" && !footer.name.isHidden)
    lostEmptyQuiet(footer.count, "recovered count after empty term")
}

/// GridViewerPresentation forwards the grid's current file as `name ?? ""`: an empty grid on page 22 or 26 sends "".
@Test(arguments: [true, false])
@MainActor func lostAndEmptyIgnoreLateEmptyFileName(lost: Bool) throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    shell.setCurrentFile("img1.png")
    if lost { lostEmptyLose(shell, .notFound) }
    else { lostEmptyShowTree(shell, cause: nil, count: 0); shell.setSearchTerm(""); lostEmptyEnterEmpty(shell) }
    shell.setCurrentFile("")
    #expect(shell.searchStatus.stringValue == (lost ? "Unavailable" : "0 images"))
    let footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, lostEmptyDash, "name after late empty file")
    lostEmptySlot(footer.count, lost ? "Unavailable" : "0 images", "count after late empty file")
}

/// CanvasWindowController.restoreEmptyFolderEntry hides the tree with `showFolder(nil)` and never clears it.
@Test @MainActor func showFolderLeavesLostAccessFooter() throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    shell.setCurrentFile("kept.png")
    lostEmptyLose(shell, .notFound)
    try lostEmptyExpectLost(shell, "before showFolder")
    shell.showFolder(nil)
    var footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, "kept.png", "after showFolder name")
    lostEmptyQuiet(footer.count, "after showFolder count")
    shell.setSearchStatus(resultCount: 4, term: "")
    footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.count, "4 images", "after count")
}

@Test(arguments: ["", "img1.png", String(repeating: "长文件名", count: 30) + ".png"], lostEmptySizes)
@MainActor func emptyFolderFooterShowsDashAndZeroImages(stored: String, size: (Int, Int)) throws {
    let (window, shell) = lostEmptyShell(width: CGFloat(size.0), height: CGFloat(size.1))
    defer { window.close() }
    shell.setCurrentFile(stored)
    lostEmptyShowTree(shell, cause: nil, count: 0)
    shell.setSearchTerm("")
    lostEmptyEnterEmpty(shell)
    #expect(shell.emptyFolderVisible)
    for term in ["", "x", String(repeating: "long-search-", count: 20)] {
        shell.setSearchStatus(resultCount: 0, term: term)
        for toggles in 0...2 {
            if toggles > 0 { shell.toggleSidebar() }
            let footer = try lostEmptyFooter(shell)
            lostEmptySlot(footer.name, lostEmptyDash, "term \(term) toggles \(toggles) name")
            lostEmptySlot(footer.count, "0 images", "term \(term) toggles \(toggles) count")
            #expect(footer.count.stringValue == String(format: String(localized: "%lld images"), 0))
        }
    }
}

enum LostElsewhere: CaseIterable, Sendable { case none, lostParent, lostChild }

@Test(arguments: LostElsewhere.allCases)
@MainActor func nonEmptyFolderFooterUnchanged(elsewhere: LostElsewhere) throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    lostEmptyShowTree(shell, cause: nil, count: 3, parentCause: elsewhere == .lostParent ? .notFound : nil,
                      childCause: elsewhere == .lostChild ? .accessExpired : nil)
    shell.setSearchTerm("")
    shell.setCurrentFile("img1.png")
    shell.setSearchStatus(resultCount: 3, term: "")
    shell.setReadingStatus(false)
    for toggles in 0...2 {
        if toggles > 0 { shell.toggleSidebar() }
        let footer = try lostEmptyFooter(shell)
        lostEmptySlot(footer.name, "img1.png", "\(elsewhere) toggles \(toggles) name")
        lostEmptySlot(footer.count, "3 images", "\(elsewhere) toggles \(toggles) count")
    }
}

enum LostEmptyPage: CaseIterable, Sendable { case lost, empty, lostAndEmpty }
enum LostEmptyRead: CaseIterable, Sendable { case reading, failed }

@MainActor private func lostEmptyEnter(_ shell: GridShellView, _ page: LostEmptyPage) {
    if page != .lost { lostEmptyShowTree(shell, cause: nil, count: 0); shell.setSearchTerm(""); lostEmptyEnterEmpty(shell) }
    if page != .empty { lostEmptyLose(shell, .diskNotConnected) }
}

@Test(arguments: LostEmptyPage.allCases, LostEmptyRead.allCases)
@MainActor func readStatusTakesPrecedenceOverLostAndEmpty(page: LostEmptyPage, read: LostEmptyRead) throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    shell.setCurrentFile("img1.png")
    lostEmptyEnter(shell, page)
    if read == .reading { shell.setReadingStatus(true) } else { shell.setReadFailedStatus(true) }
    var footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, lostEmptyDash, "\(page) \(read) name")
    lostEmptySlot(footer.count, read == .reading ? "Reading…" : "Read incomplete", "\(page) \(read) count")
    if read == .reading { shell.setReadingStatus(false) } else { shell.setReadFailedStatus(false) }
    footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, lostEmptyDash, "\(page) after \(read) name")
    lostEmptySlot(footer.count, page == .empty ? "0 images" : "Unavailable", "\(page) after \(read) count")
}

@Test(arguments: [true, false])
@MainActor func lostBeatsEmptyFolder(lostFirst: Bool) throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    if lostFirst { lostEmptyLose(shell, .accessExpired); lostEmptyEnterEmpty(shell) }
    else { lostEmptyEnterEmpty(shell); lostEmptyLose(shell, .accessExpired) }
    try lostEmptyExpectLost(shell, "both")
    shell.setEmptyFolderState(false, recents: [], now: lostEmptyNow)
    try lostEmptyExpectLost(shell, "empty ended")
}

@Test(arguments: [true, false])
@MainActor func treeClearLeavesLostAccessFooter(throughSearchTerm: Bool) throws {
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    shell.setCurrentFile("kept.png")
    lostEmptyLose(shell, .notFound)
    try lostEmptyExpectLost(shell, "before clear")
    shell.folderTree.clear()
    if throughSearchTerm { shell.setSearchTerm("") } else { shell.toggleSidebar() }
    var footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, "kept.png", "after clear name")
    lostEmptyQuiet(footer.count, "after clear count")
    shell.setSearchStatus(resultCount: 4, term: "")
    footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.count, "4 images", "after count")
}

@Test(arguments: [true, false], [480, 481])
@MainActor func narrowFooterKeepsDashHidesCount(lost: Bool, width: Int) throws {
    let (window, shell) = lostEmptyShell(width: CGFloat(width), height: 680)
    defer { window.close() }
    shell.setCurrentFile("img1.png")
    if lost { lostEmptyLose(shell, .unknown) }
    else { lostEmptyShowTree(shell, cause: nil, count: 0); shell.setSearchTerm(""); lostEmptyEnterEmpty(shell) }
    let footer = try lostEmptyFooter(shell)
    lostEmptySlot(footer.name, lostEmptyDash, "\(width) name")
    if width <= 480 { #expect(footer.count.isHidden, "\(width) count shown") }
    else { lostEmptySlot(footer.count, lost ? "Unavailable" : "0 images", "\(width) count") }
}

/// A live page 22 or 26 resized across the 480 pt footer: the count hides at 480 and returns at 481.
@Test(arguments: [true, false])
@MainActor func resizeAcross480KeepsPageFooter(lost: Bool) throws {
    let (window, shell) = lostEmptyShell(width: 481, height: 680)
    defer { window.close() }
    if lost { lostEmptyLose(shell, .diskNotConnected) }
    else { lostEmptyShowTree(shell, cause: nil, count: 0); shell.setSearchTerm(""); lostEmptyEnterEmpty(shell) }
    let text = lost ? "Unavailable" : "0 images"
    for width in [480, 481, 800, 480] as [CGFloat] {
        window.setContentSize(NSSize(width: width, height: 680))
        shell.frame = NSRect(x: 0, y: 0, width: width, height: 680)
        let footer = try lostEmptyFooter(shell)
        lostEmptySlot(footer.name, lostEmptyDash, "\(width) name")
        if width <= 480 { #expect(footer.count.isHidden, "\(width) count shown") }
        else { lostEmptySlot(footer.count, text, "\(width) count") }
    }
}

/// The law: the footer is a function of the read flag, the page (lost > empty > normal) and the last stored name and
/// count; derived text never overwrites the stored values, so every path back to normal shows them.
private enum LostEmptyOp: CustomStringConvertible {
    case reading(Bool), failed(Bool), showLost(AccessLossCause), showTree, showFolder, clearTree, empty(Bool)
    case file(Int), noFile, count(Int), search(Int), clearTerm
    var description: String {
        switch self {
        case .reading(let on): "reading(\(on))"
        case .failed(let on): "failed(\(on))"
        case .showLost(let cause): "lost(\(cause))"
        case .showTree: "tree"
        case .showFolder: "folder"
        case .clearTree: "clear"
        case .empty(let on): "empty(\(on))"
        case .file(let k): "file(\(k))"
        case .noFile: "file('')"
        case .count(let k): "count(\(k))"
        case .search(let k): "search(\(k))"
        case .clearTerm: "term('')"
        }
    }
}

private struct LostEmptyModel {
    var reading = false, failed = false, lost = false, empty = false
    var name = "start.png", count = "1 images"
    mutating func apply(_ op: LostEmptyOp) {
        switch op {
        case .reading(let on): reading = on; if on { failed = false }
        case .failed(let on): failed = on; if on { reading = false }
        case .showLost: lost = true
        case .showTree, .showFolder: lost = false
        case .clearTree: lost = false; count = ""
        case .empty(let on): empty = on
        case .file(let k): name = "f\(k).png"
        case .noFile: name = ""
        case .count(let k): count = "\(k) images"
        case .search(let k): count = "Search: x · \(k) results"
        case .clearTerm: count = ""
        }
    }
    var renderedName: String { reading || failed || lost || empty ? lostEmptyDash : name }
    var renderedCount: String {
        reading ? "Reading…" : failed ? "Read incomplete" : lost ? "Unavailable" : empty ? "0 images" : count
    }
}

@MainActor private func lostEmptyApply(_ op: LostEmptyOp, to shell: GridShellView) {
    switch op {
    case .reading(let on): shell.setReadingStatus(on)
    case .failed(let on): shell.setReadFailedStatus(on)
    case .showLost(let cause): lostEmptyShowTree(shell, cause: cause)
    case .showTree: lostEmptyShowTree(shell, cause: nil, count: 2)
    case .showFolder: shell.showFolder("待整理")
    case .clearTree: shell.folderTree.clear(); shell.setSearchTerm("")
    case .empty(let on): shell.setEmptyFolderState(on, recents: [], now: lostEmptyNow)
    case .file(let k): shell.setCurrentFile("f\(k).png")
    case .noFile: shell.setCurrentFile("")
    case .count(let k): shell.setSearchStatus(resultCount: k, term: "")
    case .search(let k): shell.setSearchStatus(resultCount: k, term: "x")
    case .clearTerm: shell.setSearchTerm("")
    }
}

private struct LostEmptySplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

@MainActor private func lostEmptyExpectModel(_ shell: GridShellView, _ model: LostEmptyModel, _ label: String) throws {
    let footer = try lostEmptyFooter(shell)
    if model.renderedName.isEmpty { lostEmptyQuiet(footer.name, "\(label) name") }
    else { lostEmptySlot(footer.name, model.renderedName, "\(label) name") }
    if model.renderedCount.isEmpty { lostEmptyQuiet(footer.count, "\(label) count") }
    else { lostEmptySlot(footer.count, model.renderedCount, "\(label) count") }
}

/// Kept cheap on purpose: one window for every sequence and 16 sequences, with every op kind and lost cause checked
/// below. A 1280×772 window per sequence for 128 sequences held the main actor long enough that, on the slower CI
/// runner, other main-actor tests passed their 120 s time limits. Each sequence starts from an explicit reset, checked against a fresh model, so a reused shell is
/// only a longer sequence of the same ops; it still yields the main actor between sequences.
@Test @MainActor func footerStatusTransitionsRestoreStoredFooter() async throws {
    var random = LostEmptySplitMix64(state: 332)
    var recoveries: [String: Int] = [:], seen: Set<String> = []
    let (window, shell) = lostEmptyShell()
    defer { window.close() }
    for sequenceIndex in 0..<16 {
        var ops: [LostEmptyOp] = (0..<8).map { _ in
            switch random.below(12) {
            case 0: .reading(random.below(2) == 0)
            case 1: .failed(random.below(2) == 0)
            case 2: .showLost(lostEmptyCauses[random.below(lostEmptyCauses.count)])
            case 3: .showTree
            case 4: .showFolder
            case 5: .clearTree
            case 6: .empty(random.below(2) == 0)
            case 7: .file(random.below(100))
            case 8: .count(random.below(100) + 1)
            case 9: .noFile
            case 10: .search(random.below(100))
            default: .clearTerm
            }
        }
        ops += [.reading(false), .failed(false), .showTree, .empty(true), .search(0),
                .reading(true), .reading(false), .failed(true), .failed(false),
                .showLost(.notFound), .showTree, .count(7), .clearTerm, .search(2), .empty(false)]
        for op: LostEmptyOp in [.reading(false), .failed(false), .showTree, .empty(false)] { lostEmptyApply(op, to: shell) }
        shell.setCurrentFile("start.png"); shell.setSearchStatus(resultCount: 1, term: "")
        var model = LostEmptyModel()
        try lostEmptyExpectModel(shell, model, "seq \(sequenceIndex) reset")
        for (step, op) in ops.enumerated() {
            seen.formUnion([op.description, String(op.description.prefix { $0 != "(" })])
            switch op {
            case .showTree, .showFolder, .clearTree: if model.lost { recoveries[op.description, default: 0] += 1 }
            case .empty(false): if model.empty { recoveries[op.description, default: 0] += 1 }
            default: break
            }
            lostEmptyApply(op, to: shell)
            model.apply(op)
            let label = "seq \(sequenceIndex) step \(step) \(ops.prefix(step + 1).map(\.description))"
            try lostEmptyExpectModel(shell, model, label)
        }
        await Task.yield()
    }
    let kinds = ["reading", "failed", "tree", "folder", "clear", "empty", "file", "file('')", "count", "search", "term"]
    for kind in kinds + lostEmptyCauses.map({ "lost(\($0))" }) { #expect(seen.contains(kind), "op \(kind) never ran") }
    for recovery in ["tree", "folder", "clear", "empty(false)"] {
        #expect(recoveries[recovery, default: 0] >= 1, "recovery \(recovery) never reached from lost/empty")
    }
}
