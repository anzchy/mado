import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func statesHiddenTransitionsRetireInputAndMatchFreshPresentation() {
    let traces: [[ViewerImageStatus]] = [
        [.empty, .showing, .empty],
        [.failed(.corruptImage, "B.jpg"), .loading("C.png"), .failed(.unsupportedFormat, "D.jpg")],
        [.loading("A.png"), .empty]
    ]
    for trace in traces {
        let scene = StatesScene()
        defer { scene.window.close() }
        scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
        for status in trace {
            let previousButtons = scene.state.buttons
            let previousChildren = scene.state.subviews
            let oldPoints = previousButtons.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: scene.content) }
            scene.state.display(status)
            let retired = previousButtons.filter { old in !scene.state.buttons.contains { $0 === old } }
            for button in retired {
                #expect(button.isHidden)
                #expect(!button.acceptsFirstResponder)
                #expect(!button.isAccessibilityEnabled())
                #expect(!button.accessibilityPerformPress())
                button.performClick(nil)
                #expect(button.nextKeyView == nil)
            }
            for child in previousChildren where !scene.state.subviews.contains(where: { $0 === child }) {
                #expect(child.isHidden)
            }
            #expect(scene.host.opens == 0)
            #expect(scene.host.navigation.isEmpty)
            if status == .showing {
                #expect(scene.state.isHidden)
                #expect((scene.state.accessibilityChildren() ?? []).isEmpty)
                for point in oldPoints { #expect(scene.content.hitTest(point) === scene.canvas) }
            } else {
                #expect(!scene.state.isHidden)
                let axButtons = (scene.state.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }
                #expect(axButtons.map { $0.accessibilityIdentifier() } == scene.state.buttons.map { $0.accessibilityIdentifier() })
                #expect(scene.state.buttons.allSatisfy { $0.isAccessibilityEnabled() })
            }
            var key: NSView? = scene.canvas
            for _ in 0..<(scene.state.buttons.count + scene.chrome.tools.count + 2) {
                key = key?.nextKeyView
                #expect(!retired.contains { $0 === key })
            }
            let fresh = StatesScene()
            fresh.state.display(status)
            #expect(scene.state.textLines == fresh.state.textLines)
            #expect(scene.state.buttons.map { $0.accessibilityIdentifier() } == fresh.state.buttons.map { $0.accessibilityIdentifier() })
            #expect(scene.state.isHidden == fresh.state.isHidden)
            fresh.window.close()
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesHiddenAncestorBlocksActionsAndEqualRefreshKeepsFocus() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
    let open = try #require(scene.state.buttons.first)
    #expect(scene.window.makeFirstResponder(open))
    for _ in 0..<3 {
        scene.state.refresh(); scene.state.display(.empty)
        #expect(scene.state.buttons.first === open)
        #expect(scene.window.firstResponder === open)
    }
    let point = open.convert(NSPoint(x: open.bounds.midX, y: open.bounds.midY), to: scene.content)
    scene.state.isHidden = true
    #expect(scene.state.hitTest(point) == nil)
    #expect(scene.content.hitTest(point) === scene.canvas)
    #expect(!open.accessibilityPerformPress())
    open.performClick(nil)
    #expect(scene.host.opens == 0)
    scene.state.isHidden = false; scene.content.isHidden = true
    #expect(scene.state.hitTest(point) == nil)
    #expect(!open.accessibilityPerformPress())
    open.performClick(nil)
    #expect(scene.host.opens == 0)
    scene.content.isHidden = false
    #expect(open.accessibilityPerformPress())
    #expect(scene.host.opens == 1)
    #expect(scene.window.makeFirstResponder(open))
    scene.state.display(.failed(.corruptImage, "B.jpg"))
    #expect(scene.window.firstResponder === scene.canvas)
    #expect(!open.accessibilityPerformPress())
    open.performClick(nil)
    #expect(scene.host.opens == 1)
    var retries = 0
    scene.state.onRetry = { retries += 1 }
    let retry = try #require(scene.state.buttons.first)
    #expect(retry.accessibilityPerformPress())
    #expect(retries == 1)
    #expect(scene.host.opens == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesHiddenLinksRefreshActualInspectorAccessibilityAndLoadingBoundary() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    // #444: page 14 has no Inspector tool; Inspector stays on View › Show Inspector (⌘I) and the 更多 menu.
    #expect(!scene.chrome.tools.contains { $0.command == .inspector })
    scene.session.setInspectorVisible(true)
    scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
    #expect(scene.session.isEnabled(.inspector))
    scene.session.setInspectorVisible(false)
    scene.state.linkKeyViews(to: scene.canvas, chrome: scene.chrome)
    #expect(!scene.session.isEnabled(.inspector))
    scene.state.display(.loading(""))
    #expect(scene.state.showsProgress)
    #expect(scene.state.textLines == ["Opening …"])
    #expect(scene.state.buttons.map { $0.accessibilityIdentifier() } == ["state.cancel"])
}
