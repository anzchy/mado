import CoreGraphics
import Testing
import MadoApplication

// #685 AC-3: the bar remembers its position per display arrangement and is clamped back on screen on restore.

private let size = CGSize(width: 562, height: 40)
private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)        // visible frame below a 25 pt menu bar
private let right = CGRect(x: 1440, y: -200, width: 1920, height: 1055)

@Test(.timeLimit(.minutes(2))) func issue685DefaultOriginIsTopCentre32BelowTheMenuBar() {
    let origin = CaptureBarPlacement.defaultOrigin(barSize: size, visibleFrame: main)
    #expect(origin == CGPoint(x: 720 - 281, y: 875 - 32 - 40))
    let onRight = CaptureBarPlacement.defaultOrigin(barSize: size, visibleFrame: right)
    #expect(onRight == CGPoint(x: 1440 + 960 - 281, y: -200 + 1055 - 32 - 40))
}

@Test(.timeLimit(.minutes(2))) func issue685ArrangementKeyIgnoresScreenOrder() {
    let a = CaptureBarPlacement.arrangementKey([main, right])
    #expect(a == CaptureBarPlacement.arrangementKey([right, main]))
    #expect(a == "0,0,1440,875;1440,-200,1920,1055")
    #expect(a != CaptureBarPlacement.arrangementKey([main]))
    #expect(CaptureBarPlacement.arrangementKey([CGRect(x: 0.4, y: 0, width: 1440.2, height: 900)]) == "0,0,1440,900")
}

@Test(.timeLimit(.minutes(2))) func issue685ClampKeepsAVisibleOriginAndPullsAnEdgeBackIn() {
    let inside = CGPoint(x: 100, y: 300)
    #expect(CaptureBarPlacement.clamp(inside, barSize: size, visibleFrames: [main, right]) == inside)
    // Hanging off the right edge of the main display, mostly on it: pulled back into main.
    #expect(CaptureBarPlacement.clamp(CGPoint(x: 1100, y: 900), barSize: size, visibleFrames: [main])
            == CGPoint(x: 1440 - 562, y: 875 - 40))
    // Overlapping both displays: goes to the one it overlaps most.
    #expect(CaptureBarPlacement.clamp(CGPoint(x: 1300, y: 100), barSize: size, visibleFrames: [main, right])
            == CGPoint(x: 1440, y: 100))
    #expect(CaptureBarPlacement.clamp(CGPoint(x: -20, y: -10), barSize: size, visibleFrames: [main])
            == CGPoint(x: 0, y: 0))
}

@Test(.timeLimit(.minutes(2))) func issue685ClampMovesAnOffScreenOriginOntoTheFirstDisplay() {
    #expect(CaptureBarPlacement.clamp(CGPoint(x: 5000, y: 3000), barSize: size, visibleFrames: [main, right])
            == CGPoint(x: 1440 - 562, y: 875 - 40))
    #expect(CaptureBarPlacement.clamp(CGPoint(x: 5000, y: 3000), barSize: size, visibleFrames: [])
            == CGPoint(x: 5000, y: 3000))
    // A bar wider than the frame starts at its left edge.
    let narrow = CGRect(x: 10, y: 0, width: 400, height: 30)
    #expect(CaptureBarPlacement.clamp(CGPoint(x: 50, y: 50), barSize: size, visibleFrames: [narrow])
            == CGPoint(x: 10, y: 0))
}

@Test(.timeLimit(.minutes(2))) func issue685RestoredOriginIsTheSavedOneClampedOrTheDefault() {
    #expect(CaptureBarPlacement.origin(saved: nil, barSize: size, visibleFrames: [main, right], pointerVisibleFrame: right)
            == CaptureBarPlacement.defaultOrigin(barSize: size, visibleFrame: right))
    #expect(CaptureBarPlacement.origin(saved: CGPoint(x: 200, y: 200), barSize: size, visibleFrames: [main],
                                       pointerVisibleFrame: main) == CGPoint(x: 200, y: 200))
    #expect(CaptureBarPlacement.origin(saved: CGPoint(x: 9000, y: 200), barSize: size, visibleFrames: [main],
                                       pointerVisibleFrame: main) == CGPoint(x: 1440 - 562, y: 200))
}
