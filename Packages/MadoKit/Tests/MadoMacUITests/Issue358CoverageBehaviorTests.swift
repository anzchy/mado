import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func issue358HitTestKeepsFirstEligibleGroupResultIncludingNil() {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 680), session: ViewerSession())
    let point = NSPoint(x: 70, y: 25)
    let front = overlay.groups[2]
    let behind = overlay.groups[1]
    let overlap = NSRect(x: 40, y: 10, width: 120, height: 38)
    front.frame = overlap
    behind.frame = overlap

    let frontHit = front.hitTest(point)
    let behindHit = behind.hitTest(point)
    #expect(frontHit != nil)
    #expect(behindHit != nil)
    #expect(frontHit !== behindHit)
    #expect(overlay.hitTest(point) === frontHit)

    front.isHidden = true
    #expect(overlay.hitTest(point) === behindHit)
    front.isHidden = false

    let hiddenAncestor = NSView(frame: overlay.bounds)
    hiddenAncestor.isHidden = true
    hiddenAncestor.addSubview(front)
    #expect(!front.isHidden)
    #expect(front.frame.contains(point))
    #expect(front.hitTest(point) == nil)
    #expect(behind.hitTest(point) != nil)
    #expect(overlay.hitTest(point) == nil)

    #expect(overlay.hitTest(NSPoint(x: -1, y: point.y)) == nil)
    behind.isHidden = true
    #expect(overlay.hitTest(point) == nil)

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
    let shifted = ViewerChromeOverlay(frame: NSRect(x: 100, y: 50, width: 640, height: 680), session: ViewerSession())
    container.addSubview(shifted)
    let local = NSPoint(x: 70, y: 25)
    let group = shifted.groups[2]
    group.frame = overlap
    #expect(group.hitTest(local) != nil)
    #expect(shifted.hitTest(NSPoint(x: 170, y: 75)) === group.hitTest(local))
    #expect(shifted.hitTest(NSPoint(x: 99, y: 75)) == nil)
}
