import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@MainActor private func chromeRaster(_ view: NSView, in rect: NSRect) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width),
        pixelsHigh: Int(rect.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = rect.size
    view.cacheDisplay(in: rect, to: rep)
    return rep
}

@MainActor private func chromeInk(_ rep: NSBitmapImageRep) -> [Bool] {
    (0..<rep.pixelsHigh).flatMap { y in
        (0..<rep.pixelsWide).map { x in
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.1 &&
                min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeLightPanelHasRenderedContourAwayFromControls() throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 480, height: 240),
        session: ViewerSession())
    overlay.appearance = NSAppearance(named: .aqua)
    overlay.refresh(filename: "landscape-3x2.png")

    // Native cacheDisplay does not composite layer-backed descendants of a parent.
    // Render the group itself; the left edge is clear of icon ink.
    let strip = try chromeRaster(overlay.groups[0], in: NSRect(x: 0, y: 9, width: 6, height: 20))
    let ink = (0..<strip.pixelsHigh).flatMap { y in
        (0..<strip.pixelsWide).map { x in
            guard let color = strip.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.1 && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.99
        }
    }
    let edgeInk = (0...2).reduce(0) { count, x in
        count + (0..<strip.pixelsHigh).filter { ink[$0 * strip.pixelsWide + x] }.count
    }
    #expect(edgeInk > 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeShortNamesDrawInFullAndLongNameTruncates() throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
        session: ViewerSession())
    let label = try #require(overlay.groups[1].subviews.compactMap { $0 as? NSTextField }.first)
    for width: CGFloat in [1280, 800] {
        overlay.setFrameSize(NSSize(width: width, height: 680))
        for name in ["landscape-3x2.png", "corrupt.png"] {
            overlay.refresh(filename: name)
            let actualWidth = Int(label.bounds.width)
            let actualInk = chromeInk(try chromeRaster(label, in: label.bounds))
            let oldSize = label.frame.size
            label.setFrameSize(NSSize(width: 420, height: oldSize.height))
            let referenceInk = chromeInk(try chromeRaster(label, in: label.bounds))
            label.setFrameSize(oldSize)
            #expect(actualInk.filter { $0 }.count > 20)
            let mismatches = (0..<Int(oldSize.height)).reduce(0) { count, y in
                count + (0..<actualWidth).filter { actualInk[y * actualWidth + $0] != referenceInk[y * 420 + $0] }.count
            }
            #expect(mismatches == 0)
        }
    }

    let longName = String(repeating: "相册-long-name-", count: 12) + ".png"
    overlay.refresh(filename: longName)
    let actualWidth = Int(label.bounds.width)
    let actualInk = chromeInk(try chromeRaster(label, in: label.bounds))
    let oldSize = label.frame.size
    label.setFrameSize(NSSize(width: 800, height: oldSize.height))
    let referenceInk = chromeInk(try chromeRaster(label, in: label.bounds))
    label.setFrameSize(oldSize)
    let mismatches = (0..<Int(oldSize.height)).reduce(0) { count, y in
        count + (0..<actualWidth).filter { actualInk[y * actualWidth + $0] != referenceInk[y * 800 + $0] }.count
    }
    #expect(mismatches > 10)
    #expect(overlay.groups[1].frame.width <= 260)
    #expect(label.accessibilityValue() as? String == longName)
}
