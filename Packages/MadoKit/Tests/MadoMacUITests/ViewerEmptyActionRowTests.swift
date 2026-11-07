import AppKit
import Testing
@testable import MadoMacUI

@MainActor private func emptyActionView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let view = emptyActionView(id, in: child) { return view }
    }
    return nil
}

@MainActor private func emptyActionFrame(_ id: String, in host: ViewerStateHost) throws -> NSRect {
    let view = try #require(emptyActionView(id, in: host))
    return host.convert(view.bounds, from: view)
}

@MainActor private func sizeEmptyScene(_ scene: StatesScene, to size: NSSize) {
    scene.window.setContentSize(size)
    scene.content.frame = NSRect(origin: .zero, size: size)
    scene.state.frame = scene.content.bounds
    scene.state.layoutSubtreeIfNeeded()
}

@Test @MainActor func issue92EmptyActionsInlineAtWideEnglishAndChineseSizes() throws {
    let scene = StatesScene(width: 1280)
    defer { scene.window.close() }
    for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 600)] {
        scene.state.display(.failed(.corruptImage, "B.jpg"))
        scene.state.display(.empty)
        sizeEmptyScene(scene, to: size)
        let action = try emptyActionFrame("state.open", in: scene.state)
        let shortcut = try emptyActionFrame("first-launch.shortcut", in: scene.state)
        #expect(abs(shortcut.minX - action.maxX - 12) <= 0.5)
        #expect(abs(shortcut.midY - action.midY) <= 0.5)
        #expect(scene.state.bounds.insetBy(dx: 16, dy: 16).contains(action))
        #expect(scene.state.bounds.insetBy(dx: 16, dy: 16).contains(shortcut))
        let children = try #require(scene.state.accessibilityChildren() as? [NSView])
        let button = try #require(emptyActionView("state.open", in: scene.state))
        let hint = try #require(emptyActionView("first-launch.shortcut", in: scene.state))
        #expect(try #require(children.firstIndex { $0 === button }) < #require(children.firstIndex { $0 === hint }))
    }
}

@Test @MainActor func issue92EmptyActionsRemainContainedAtCompactSize() throws {
    let scene = StatesScene(width: 360)
    defer { scene.window.close() }
    scene.state.display(.empty)
    sizeEmptyScene(scene, to: NSSize(width: 360, height: 680))
    let action = try emptyActionFrame("state.open", in: scene.state)
    let shortcut = try emptyActionFrame("first-launch.shortcut", in: scene.state)
    #expect(action.minX >= 16)
    #expect(shortcut.maxX <= scene.state.bounds.maxX - 16)
    #expect(abs(shortcut.midY - action.midY) <= 0.5)
    #expect(try emptyActionFrame("first-launch.wall", in: scene.state) == NSRect(x: 0, y: 0, width: 360, height: 642))
    let drop = try emptyActionFrame("first-launch.drop", in: scene.state)
    #expect(drop.contains(action) && drop.contains(shortcut))
}
