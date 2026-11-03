import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

@MainActor private func stateView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let match = stateView(id, in: child) { return match }
    }
    return nil
}

@MainActor private func frame(_ id: String, in host: ViewerStateHost) throws -> NSRect {
    let view = try #require(stateView(id, in: host))
    return host.convert(view.bounds, from: view)
}

@Test @MainActor func issue92EmptyStateComposesSemanticContent() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    scene.state.display(.empty)
    scene.state.layoutSubtreeIfNeeded()
    let wall = try frame("first-launch.wall", in: scene.state)
    let heading = try frame("first-launch.heading", in: scene.state)
    let action = try frame("state.open", in: scene.state)
    let hint = try frame("first-launch.shortcut", in: scene.state)
    #expect(wall == NSRect(x: 0, y: 0, width: 960, height: 602))
    #expect(stateView("first-launch.wall", in: scene.state)?.isAccessibilityElement() == false)
    #expect(!(scene.state.accessibilityChildren() ?? []).contains { ($0 as? NSView)?.accessibilityIdentifier() == "first-launch.wall" })
    #expect(heading.minY > action.maxY)
    #expect(abs(heading.midX - scene.state.bounds.midX) < 1)
    #expect(abs(hint.minX - action.maxX - 12) <= 0.5)
    #expect(abs(hint.midY - action.midY) <= 0.5)
    #expect(stateView("first-launch.heading", in: scene.state)?.accessibilityLabel() == scene.state.textLines[0])
}

@Test @MainActor func issue92FailureStateTruncatesAtCompactSizeAndTracksNext() throws {
    let scene = StatesScene(width: 800)
    defer { scene.window.close() }
    scene.state.frame.size.height = 680
    let longName = String(repeating: "long-file-name-", count: 14) + ".jpg"
    scene.state.display(.failed(.corruptImage, longName), nextEnabled: true)
    scene.state.layoutSubtreeIfNeeded()
    let icon = try frame("state.icon", in: scene.state)
    let heading = try frame("state.heading", in: scene.state)
    let filename = try frame("state.filename", in: scene.state)
    let retry = try frame("state.retry", in: scene.state)
    let next = try frame("state.next", in: scene.state)
    #expect(icon.size == NSSize(width: 32, height: 32))
    #expect(stateView("state.icon", in: scene.state)?.accessibilityLabel() == "Unreadable image")
    #expect(icon.minY > heading.maxY)
    #expect(heading.minY > filename.maxY)
    #expect(filename.minY > retry.maxY)
    #expect(abs(filename.height - 22.1) <= 1)
    #expect(retry.minX < next.minX)
    #expect(retry.minY > 80)
    scene.state.display(.failed(.corruptImage, longName), nextEnabled: false)
    scene.state.layoutSubtreeIfNeeded()
    #expect(stateView("state.next", in: scene.state) == nil)
    #expect(stateView("state.retry", in: scene.state) != nil)
}

@MainActor private func assertVisibleComposition(
    _ state: ViewerStateHost, ids: [String], expectedGaps: [(String, String, CGFloat)]
) throws {
    state.layoutSubtreeIfNeeded()
    let views = try ids.map { try #require(stateView($0, in: state)) }
    let frames = views.map { state.convert($0.bounds, from: $0) }
    let union = frames.dropFirst().reduce(try #require(frames.first)) { $0.union($1) }
    let visible = state.bounds.insetBy(dx: 16, dy: 16)
    #expect(abs(union.midX - state.bounds.midX) <= 1)
    #expect(abs(union.midY - state.bounds.midY) <= 1)
    for (view, rect) in zip(views, frames) {
        #expect(!view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0)
        #expect(rect.width > 0 && rect.height > 0)
        #expect(visible.contains(rect))
    }
    let icon = try #require(stateView("state.icon", in: state) as? NSImageView)
    #expect(icon.image != nil)
    #expect(icon.image?.size.width ?? 0 > 0)
    #expect(icon.accessibilityRole() == .image)
    for (upper, lower, distance) in expectedGaps {
        let measured = try frame(upper, in: state).minY - frame(lower, in: state).maxY
        #expect(abs(measured - distance) <= 0.5)
    }
}

@Test @MainActor func issue92CompleteStateCompositionSurvivesResize() throws {
    let scene = StatesScene(width: 1280)
    defer { scene.window.close() }
    for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)] {
        scene.window.setContentSize(size)
        scene.content.frame = NSRect(origin: .zero, size: size)
        scene.state.frame = scene.content.bounds
        #expect(scene.window.contentView?.bounds.size == size)
        #expect(scene.state.bounds.size == size)
        scene.state.display(.failed(.corruptImage, "very-long-" + String(repeating: "摄影旅行照片-", count: 18) + ".jpg"), nextEnabled: true)
        try assertVisibleComposition(scene.state,
            ids: ["state.icon", "state.heading", "state.filename", "state.retry", "state.next"],
            expectedGaps: [("state.icon", "state.heading", 18), ("state.heading", "state.filename", 9),
                           ("state.filename", "state.retry", 22)])
        let retry = try frame("state.retry", in: scene.state)
        let next = try frame("state.next", in: scene.state)
        #expect(abs(next.minX - retry.maxX - 16) <= 0.5)
        #expect(abs(try frame("state.filename", in: scene.state).height - 22.1) <= 1)
        scene.state.display(.empty)
        scene.state.layoutSubtreeIfNeeded()
        let wall = try frame("first-launch.wall", in: scene.state)
        let heading = try frame("first-launch.heading", in: scene.state)
        let open = try frame("state.open", in: scene.state)
        let hint = try frame("first-launch.shortcut", in: scene.state)
        #expect(wall == NSRect(x: 0, y: 0, width: size.width, height: size.height - 38))
        #expect(heading.minY > open.maxY)
        #expect(abs(hint.minX - open.maxX - 12) <= 0.5)
    }
}

private func appTranslation(_ key: String, language: String) throws -> String {
    let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../App/Resources/Localizable.xcstrings").standardizedFileURL
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    let localized = try #require(localizations[language] as? [String: Any])
    let unit = try #require(localized["stringUnit"] as? [String: Any])
    return try #require(unit["value"] as? String)
}

@Test @MainActor func issue92IconLabelsResolveInEnglishAndChinese() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Issue92StateLabels-\(UUID().uuidString).bundle", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Contents", isDirectory: true)
    let resources = contents.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "picsee.issue92.labels", "CFBundleDevelopmentRegion": "en"]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    for language in ["en", "zh-Hans"] {
        let folder = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entries = try ["Open folder", "Unreadable image"].map { key in
            "\"\(key)\" = \"\(try appTranslation(key, language: language))\";"
        }
        try entries.joined(separator: "\n").write(to: folder.appendingPathComponent("Localizable.strings"),
                                                 atomically: true, encoding: .utf8)
    }
    let bundle = try #require(Bundle(path: root.path))
    for (language, empty, failed) in [("en", "Open folder", "Unreadable image"),
                                      ("zh-Hans", "打开文件夹", "无法读取的图片")] {
        let locale = Locale(identifier: language)
        #expect(ViewerStateHost.stateIconLabel(failure: false, bundle: bundle, locale: locale) == empty)
        #expect(ViewerStateHost.stateIconLabel(failure: true, bundle: bundle, locale: locale) == failed)
    }
    #expect(ViewerStateHost.stateIconLabel(failure: false, bundle: bundle,
                                          locale: Locale(identifier: "fr")) == "Open folder")
}

@Test @MainActor func issue92LongChineseStateCopyRemainsContained() throws {
    let scene = StatesScene(width: 800)
    defer { scene.window.close() }
    let size = NSSize(width: 800, height: 680)
    scene.window.setContentSize(size)
    scene.content.frame = NSRect(origin: .zero, size: size)
    scene.state.frame = scene.content.bounds
    scene.state.display(.empty)
    let heading = try #require(stateView("first-launch.heading", in: scene.state) as? NSTextField)
    let hint = try #require(stateView("first-launch.shortcut", in: scene.state) as? NSTextField)
    heading.stringValue = try appTranslation("Drop a photo folder here", language: "zh-Hans")
    hint.stringValue = try appTranslation("or press ⌘O", language: "zh-Hans")
    scene.state.needsLayout = true
    scene.state.layoutSubtreeIfNeeded()
    #expect(scene.state.bounds.contains(try frame("first-launch.heading", in: scene.state)))
    #expect(scene.state.bounds.contains(try frame("first-launch.shortcut", in: scene.state)))

    scene.state.display(.failed(.corruptImage, String(repeating: "旅行照片-", count: 25) + ".jpg"), nextEnabled: true)
    let message = try #require(stateView("state.filename", in: scene.state) as? NSTextField)
    scene.state.needsLayout = true
    try assertVisibleComposition(scene.state,
        ids: ["state.icon", "state.heading", "state.filename", "state.retry", "state.next"],
        expectedGaps: [("state.icon", "state.heading", 18), ("state.heading", "state.filename", 9),
                       ("state.filename", "state.retry", 22)])
    #expect(abs(try frame("state.filename", in: scene.state).height - 22.1) <= 1)
    #expect(message.lineBreakMode == .byClipping && message.maximumNumberOfLines == 1)
    #expect(message.stringValue.hasSuffix(scene.state.textLines[2]))
    #expect(message.toolTip == scene.state.textLines[1] + " · " + scene.state.textLines[2])
}
