import AppKit
@testable import Mado
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

@Test(.timeLimit(.minutes(3))) @MainActor
func issue527InactiveFirstClickKeepsFocusConsistent() async throws {
    let scene = try Issue527Scene()
    defer { scene.close() }
    // Reserve 15 s for key acquisition within this test's existing limit.
    try await scene.open(keyWindowTimeout: .seconds(180) / 12)
    let tool = try scene.focusTool()
    let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 220, height: 150),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    other.makeKeyAndOrderFront(nil)
    try await scene.wait { other.isKeyWindow }
    try #require(!scene.window.isKeyWindow && scene.window.firstResponder === tool)
    try #require(scene.controller.session.inspectorFocus.focus == .tools)
    func record(_ phase: String) {
        let responder = scene.window.firstResponder
        let identifier = (responder as? NSView)?.accessibilityIdentifier() ?? "nil"
        print("[issue527-inactive] phase=\(phase) key=\(scene.window.isKeyWindow) otherKey=\(other.isKeyWindow) focus=\(scene.controller.session.inspectorFocus.focus) responder=\(responder.map { String(reflecting: type(of: $0)) } ?? "nil") id=\(identifier) canvas=\(responder === scene.canvas)")
    }
    record("before")
    let point = scene.canvas.convert(CGPoint(x: scene.canvas.bounds.midX, y: scene.canvas.bounds.midY), to: nil)
    try #require(scene.hit(at: point) === scene.canvas)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        scene.eventNumber += 1
        let event = try #require(NSEvent.mouseEvent(with: type, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: scene.window.windowNumber, context: nil, eventNumber: scene.eventNumber,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        NSApp.sendEvent(event)
        record(type == .leftMouseDown ? "afterDown" : "afterUp")
    }
    try await scene.wait { scene.window.isKeyWindow }
    record("activated")
    let canvasOwnsFocus = scene.window.firstResponder === scene.canvas
    let toolOwnsFocus = scene.window.firstResponder === tool
    let focus = scene.controller.session.inspectorFocus.focus
    #expect((canvasOwnsFocus && focus == .canvas) || (toolOwnsFocus && focus == .tools),
        "the first click must leave Session and native responder consistent, whether activation-only or accepted")
    let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: scene.window.windowNumber, context: nil, characters: "\t",
        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    scene.window.sendEvent(tab)
    record("afterTab")
    let expected = canvasOwnsFocus ? "chrome.sidebar.button" : "chrome.more.button"
    #expect((scene.window.firstResponder as? NSView)?.accessibilityIdentifier() == expected,
        "Tab follows the actual first-click responder rather than a divergent Session focus")
    #expect(scene.controller.session.inspectorFocus.focus == .tools)
    #expect(scene.controller.session.mode == .viewing)
}
