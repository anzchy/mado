import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #692 fix r1 (gpt F1, opus M4): every completed mark is an accessibility child of the overlay, with its kind as the
// label, a text mark's words as the value, a step's current number, the selection, and frames that follow the mark.
// Page 39's transform: zoom 0.32, origin 352,16, so image (x, y) is view (352 + 0.32x, 16 + 0.32y).

private let page39 = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
private let style = AnnotationStyle.forScreen(pointsPerImagePixel: 0.32)

@MainActor private final class Flipped: NSView { override var isFlipped: Bool { true } }

@MainActor private func host() -> (AnnotationOverlayView, NSWindow) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1280, height: 800), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = Flipped(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    window.contentView = container
    let overlay = AnnotationOverlayView(frame: container.bounds)
    container.addSubview(overlay)
    overlay.transform = page39
    overlay.imageSize = CGSize(width: 1600, height: 2400)
    overlay.isActive = true
    overlay.tool = .select
    return (overlay, window)
}

@MainActor private func elements(_ overlay: AnnotationOverlayView) -> [NSAccessibilityElement] {
    (overlay.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
}

/// The element at `index`, failing (not trapping) on a red run.
private func at(_ children: [NSAccessibilityElement], _ index: Int) throws -> NSAccessibilityElement {
    try #require(children.indices.contains(index) ? children[index] : nil, "child \(index) of \(children.count)")
}

private func sevenMarks() -> [AnnotationMark] {
    [AnnotationMark(rect: CGRect(x: 100, y: 100, width: 200, height: 100), style: style),
     .arrow(tail: CGPoint(x: 100, y: 600), tip: CGPoint(x: 400, y: 400), style: style),
     .text("从这里上岸", origin: CGPoint(x: 600, y: 300), size: CGSize(width: 300, height: 60), style: style),
     .stroke(.highlighter, points: [CGPoint(x: 700, y: 700), CGPoint(x: 900, y: 760)], style: style),
     .stroke(.pen, points: [CGPoint(x: 700, y: 900), CGPoint(x: 800, y: 1000), CGPoint(x: 900, y: 900)], style: style),
     .step(centre: CGPoint(x: 1000, y: 1200), style: style),
     .step(centre: CGPoint(x: 1200, y: 1200), style: style)]
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692MarkAccessibilityLabelsValuesAndParent() throws {
    let (overlay, window) = host()
    defer { window.close() }
    #expect(elements(overlay).isEmpty, "no marks, no children")
    overlay.marks = sevenMarks()
    let children = elements(overlay)
    #expect(children.count == 7)
    #expect(children.map { $0.accessibilityLabel() ?? "" }
            == ["Rectangle", "Arrow", "Text", "Highlighter", "Pen", "Step 1", "Step 2"])
    #expect(try at(children, 2).accessibilityValue() as? String == "从这里上岸", "a text mark reads its words")
    for (index, child) in children.enumerated() where index != 2 {
        #expect(child.accessibilityValue() == nil, "\(index) has no value")
    }
    for child in children {
        #expect(child.accessibilityParent() as? AnnotationOverlayView === overlay)
        #expect(child.accessibilityRole() == .layoutItem)
        #expect(child.isAccessibilityElement())
    }
    #expect(overlay.isAccessibilityElement(), "the marks sit in one group")
    #expect(overlay.accessibilityRole() == .group)
    #expect(overlay.accessibilityLabel() == "Annotations")
    #expect(elements(overlay).map { ObjectIdentifier($0) } == children.map { ObjectIdentifier($0) },
            "the same elements while the marks stay, so VoiceOver keeps its place")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692MarkAccessibilitySelectedStateFollowsTheSelection() throws {
    let (overlay, window) = host()
    defer { window.close() }
    overlay.marks = sevenMarks()
    #expect(elements(overlay).map { $0.isAccessibilitySelected() } == Array(repeating: false, count: 7))
    #expect(overlay.accessibilitySelectedChildren()?.isEmpty == true)
    overlay.selectedMark = 2
    let children = elements(overlay)
    #expect(children.map { $0.isAccessibilitySelected() } == [false, false, true, false, false, false, false])
    let selected = overlay.accessibilitySelectedChildren() ?? []
    let third = try at(children, 2)
    #expect(selected.count == 1 && (selected.first as? NSAccessibilityElement) === third)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692MarkAccessibilityRenumbersAfterADelete() throws {
    let (overlay, window) = host()
    defer { window.close() }
    let steps = [CGPoint(x: 400, y: 400), CGPoint(x: 600, y: 400), CGPoint(x: 800, y: 400)]
        .map { AnnotationMark.step(centre: $0, style: style) }
    overlay.marks = steps
    #expect(elements(overlay).map { $0.accessibilityLabel() ?? "" } == ["Step 1", "Step 2", "Step 3"])
    let kept = try at(elements(overlay), 0)
    overlay.marks = [steps[0], steps[2]]
    #expect(elements(overlay).count == 2)
    #expect(elements(overlay).map { $0.accessibilityLabel() ?? "" } == ["Step 1", "Step 2"], "the third is now 2")
    #expect(try at(elements(overlay), 0) === kept)
    overlay.marks = steps
    #expect(elements(overlay).map { $0.accessibilityLabel() ?? "" } == ["Step 1", "Step 2", "Step 3"], "undo brings 3 back")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692MarkAccessibilityFramesFollowMoveResizeAndZoom() throws {
    let (overlay, window) = host()
    defer { window.close() }
    let rect = AnnotationMark(rect: CGRect(x: 100, y: 100, width: 200, height: 100), style: style)
    overlay.marks = [rect]
    func screen(_ view: CGRect) -> CGRect { window.convertToScreen(overlay.convert(view, to: nil)) }
    func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01
            && abs(a.height - b.height) < 0.01
    }
    var frame = try #require(elements(overlay).first).accessibilityFrame()
    #expect(same(frame, screen(CGRect(x: 384, y: 48, width: 64, height: 32))), "\(frame)")
    // Moved by 100 image pixels right: 32 points.
    overlay.marks = [AnnotationGeometry.translate(rect, by: CGVector(dx: 100, dy: 0), imageSize: overlay.imageSize)]
    frame = try #require(elements(overlay).first).accessibilityFrame()
    #expect(same(frame, screen(CGRect(x: 416, y: 48, width: 64, height: 32))), "moved: \(frame)")
    // Resized by its bottom-right handle to image (500, 400).
    overlay.marks = [AnnotationGeometry.resize(overlay.marks[0], handle: .bottomRight, to: CGPoint(x: 500, y: 400),
                                               imageSize: overlay.imageSize)]
    frame = try #require(elements(overlay).first).accessibilityFrame()
    #expect(same(frame, screen(CGRect(x: 416, y: 48, width: 96, height: 96))), "resized: \(frame)")
    // Zoom 0.5 at origin 10,20.
    overlay.transform = CanvasTransform(backingScale: 1, zoom: 0.5, origin: CGPoint(x: 10, y: 20))
    frame = try #require(elements(overlay).first).accessibilityFrame()
    #expect(same(frame, screen(CGRect(x: 110, y: 70, width: 150, height: 150))), "zoomed: \(frame)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692MarkAccessibilitySelectsAndDeletes() throws {
    let (overlay, window) = host()
    defer { window.close() }
    overlay.marks = sevenMarks()
    var selected: [Int?] = []
    var deleted: [Int] = []
    overlay.onSelect = { selected.append($0) }
    overlay.onDelete = { deleted.append($0) }
    let children = elements(overlay)
    try at(children, 1).setAccessibilitySelected(true)
    #expect(selected == [1], "selecting through accessibility selects the mark")
    #expect(try at(children, 4).accessibilityPerformPress())
    #expect(selected == [1, 4], "a press selects too")
    overlay.selectedMark = 4
    try at(children, 4).setAccessibilitySelected(false)
    #expect(selected == [1, 4, nil], "deselecting the selected mark clears the selection")
    try at(children, 3).setAccessibilitySelected(false)
    #expect(selected == [1, 4, nil], "deselecting another mark changes nothing")
    let actions = try at(children, 5).accessibilityCustomActions() ?? []
    #expect(actions.map(\.name) == ["Delete"])
    #expect(try #require(actions.first).handler?() == true)
    #expect(deleted == [5], "the delete action names the mark")
}
