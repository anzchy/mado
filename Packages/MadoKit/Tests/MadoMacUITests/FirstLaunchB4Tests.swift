import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@MainActor private func b4View(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = b4View(id, in: child) { return found }
    }
    return nil
}

// Design: 9234b14, prototype-first-launch-b4-final.html SHA-256
// 8ba81de68f67911b0c3bdfbc90ff1513860ebf41d32c9b216fef6be8576d50da.
@Test(.timeLimit(.minutes(2))) @MainActor func p316B4FirstLaunchPresentsPinnedCentre() throws {
    let scene = StatesScene(width: 960)
    defer { scene.window.close() }
    scene.state.display(.empty)
    scene.state.layoutSubtreeIfNeeded()
    #expect(scene.state.textLines == ["Drop a photo folder here", "or press ⌘O"])
    #expect(scene.state.buttons.map(\.title) == ["Choose Folder…"])
    #expect(b4View("first-launch.stack", in: scene.state) == nil)
    #expect(b4View("first-launch.drop", in: scene.state) != nil)
    #expect(b4View("first-launch.print.alley", in: scene.state) == nil)
    #expect(b4View("first-launch.chip.images", in: scene.state) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4DecoderInitIsUnavailable() {
    #expect(FirstLaunchView(coder: NSCoder()) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4PinnedCSSMatchesRenderedCentre() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("B4PinnedDesign")
    let source = fixtureRoot.appendingPathComponent("a/b/c/d/source.swift").path
    let css = try PinnedDesign.page("b4-first-launch", source: source)
    let scene = StatesScene()
    defer { scene.window.close() }
    scene.state.layoutSubtreeIfNeeded()
    let drop = try #require(b4View("first-launch.drop", in: scene.state))
    let heading = try #require(b4View("first-launch.heading", in: scene.state) as? NSTextField)
    try css.assertLength(Double(heading.font!.pointSize), ".drop h1", "font-size", viewport: 960)
    // #315 AC7 (added scope from #313): the drop outline follows pinned page 21, inset 18 inside the content
    // area below the 38-pt titlebar strip, so the centre sits 12 pt lower than B4's `.drop` margin placed it.
    let page = try PinnedDesign.page("first-launch")
    let inset = try page.length(".drop-outline", "inset", viewport: 960)
    let titleBar = try page.length(":root", "--title-bar-height", viewport: 960)
    #expect(Double(drop.frame.minX) == inset)
    #expect(Double(scene.state.bounds.maxX - drop.frame.maxX) == inset)
    #expect(Double(drop.frame.minY) == inset)
    #expect(Double(scene.state.bounds.maxY) - titleBar - Double(drop.frame.maxY) == inset)
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4PinnedCentreSpacingAndButtonGroup() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("B4PinnedDesign")
    let css = try PinnedDesign.page("b4-first-launch", source: fixtureRoot.appendingPathComponent("a/b/c/d/source.swift").path)
    let scene = StatesScene()
    defer { scene.window.close() }
    scene.state.layoutSubtreeIfNeeded()
    let heading = try #require(b4View("first-launch.heading", in: scene.state))
    let button = try #require(scene.state.buttons.first)
    let shortcut = try #require(b4View("first-launch.shortcut", in: scene.state))
    let key = try #require(b4View("first-launch.shortcut-key", in: scene.state) as? NSTextField)
    let group = button.frame.union(shortcut.frame).union(key.frame)
    #expect(abs(group.midX - scene.state.bounds.midX) <= 1)
    #expect(abs(group.midY - button.frame.midY) <= 1)
    let gap = try css.length(".centre", "gap", viewport: 960)
    #expect(abs(Double(heading.frame.minY - button.frame.maxY) - gap) <= 1)
    try css.assertLength(Double(shortcut.frame.minX - button.frame.maxX), ".sub", "gap", viewport: 960, tolerance: 1)
    let padding = try css.edges(".btn", "padding", viewport: 960)
    let titleWidth = ceil((button.title as NSString).size(withAttributes: [.font: button.font!]).width)
    #expect(abs(Double(button.frame.width - titleWidth) - padding.left - padding.right) <= 2)
    try css.assertLength(Double(key.font!.pointSize), "kbd", "font-size", viewport: 960)
    #expect(abs(key.frame.midY - button.frame.midY) <= 1)
}

// #441, owner 2026-11-03: 「打开首页的这行字我不喜欢，删掉」. The Home has no chips row in either language, in any
// presentation; exact matches, since "Folder" is inside "Choose Folder…" and 文件夹 inside 选择文件夹….
@Test(.timeLimit(.minutes(2))) @MainActor func i441HomeHasNoChipsInEitherLanguage() throws {
    let chipText: Set<String> = ["Folder", "One or more images", "Common image formats", "文件夹", "单张或多张图片", "常见图片格式"]
    let scene = StatesScene(width: 960)
    defer { scene.window.close() }
    scene.state.display(.empty)
    let size = NSSize(width: 1280, height: 800)
    scene.window.setContentSize(size)
    scene.content.frame = NSRect(origin: .zero, size: size)
    scene.state.frame = scene.content.bounds
    scene.state.layoutSubtreeIfNeeded()
    let launch = try #require(scene.state.subviews.compactMap { $0 as? FirstLaunchView }.first)
    let heading = try #require(b4View("first-launch.heading", in: launch) as? NSTextField)
    let shortcut = try #require(b4View("first-launch.shortcut", in: launch) as? NSTextField)
    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    func check(_ step: String) throws {
        launch.needsLayout = true
        launch.layoutSubtreeIfNeeded()
        let views = descendants(launch)
        #expect(!views.contains { $0.accessibilityIdentifier().hasPrefix("first-launch.chip.") }, "\(step) chip view")
        let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }
        let labels = views.compactMap { $0.accessibilityLabel() }
        #expect(texts.filter(chipText.contains).isEmpty, "\(step) chip text \(texts)")
        #expect(labels.filter(chipText.contains).isEmpty, "\(step) chip label \(labels)")
        let open = try #require(b4View("state.open", in: launch) as? NSButton, "\(step)")
        #expect(open.title == "Choose Folder…", "\(step) button")
    }
    try check("idle")
    launch.setDragActive(true); try check("drag")
    launch.setDragActive(false); try check("idle again")
    launch.themeOverride = .dark; launch.appearance = NSAppearance(named: .darkAqua); try check("dark")
    launch.setDragActive(true); try check("dark drag")
    launch.setDragActive(false)
    heading.stringValue = "把照片文件夹拖到这里"; shortcut.stringValue = "或按 ⌘O"; try check("zh idle")
    launch.setDragActive(true)
    heading.stringValue = "松开即可打开"; try check("zh drag")
}
