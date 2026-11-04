import AppKit
import QuartzCore
import Testing
@testable import PicseeMacUI

@Suite(.serialized) @MainActor struct Issue499PrimaryFrameTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_I499_GUI_ACQUISITION"] != nil,
        "Opt-in real-window check requires a caller-owned PICSEE_I499_GUI_ACQUISITION; routine tests skip without taking a GUI lease, whether the desktop is free or busy."),
        .timeLimit(.minutes(2)))
    func issue499RealHomePrimaryFrame() throws {
        try validate499BorrowedGUILease()
        let scene = StatesScene()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scene.content
        scene.host.window = window
        defer { window.close(); scene.window.close() }
        let oldPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(oldPolicy) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // CFRunLoop timers can run inside NSApp.run; dispatch-main closures cannot
        // reenter the currently executing Swift Testing MainActor block.
        var captureError: Error?
        var samples: [Primary499Sample] = []
        var timerFired = false
        let captureTimer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                timerFired = true
                defer {
                    NSApp.stop(nil)
                    let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        subtype: 0, data1: 0, data2: 0)!
                    NSApp.postEvent(event, atStart: true)
                }
                do {
                    samples = try capture499(scene: scene, window: window)
                } catch { captureError = error }
            }
        }
        RunLoop.main.add(captureTimer, forMode: .common)
        NSApp.run()
        #expect(timerFired)
        if let captureError { throw captureError }
        #expect(samples.count == 9)
        for sample in samples {
            try #require(sample.active && sample.key, "Invalid reproduction: window is not active and key")
            #expect(sample.opaque > sample.area / 2)
            try #require(sample.blue > sample.area / 4, "Invalid reproduction: accent fill is absent")
            // AppKit brightens the native bezel; tolerate that without accepting an unrelated fill.
            if sample.state != .pressed { #expect(sample.fillError <= 0.12) }
            #expect(sample.white >= 20)
            #expect(sample.rows >= 3 && sample.columns >= 8)
            #expect(sample.dark <= 4)
            #expect(sample.offSegment <= 4)
            #expect(sample.frame == samples.first?.frame)
            #expect(sample.frame.size == NSSize(width: 130, height: 30))
        }
    }
}


@MainActor private func capture499(scene: StatesScene, window: NSWindow) throws -> [Primary499Sample] {
    var samples: [Primary499Sample] = []
    window.makeKeyAndOrderFront(nil)
    window.makeMain()
    NSApp.activate(ignoringOtherApps: true)
    let button = try unwrap499(scene.state.buttons.first { $0.identifier?.rawValue == "state.open" })
    let launch = try unwrap499(button.superview as? FirstLaunchView)
    launch.pinAccessibility(reduceMotion: true)
    let originalTitle = button.title
    let originalAXTitle = button.accessibilityTitle()
    #expect(originalTitle == "Choose Folder…")
    #expect(originalAXTitle == "Choose Folder…")
    let evidence: URL?
    if ProcessInfo.processInfo.environment["PICSEE_I499_EVIDENCE"] == "1" {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("i499-evidence-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("i499 evidence: \(directory.path)")
        evidence = directory
    } else {
        evidence = nil
    }
    for (step, appearance) in [NSAppearance.Name.aqua, .darkAqua, .aqua].enumerated() {
        window.appearance = try unwrap499(NSAppearance(named: appearance))
        for state in Primary499State.allCases {
            button.highlight(false)
            try #require(window.makeFirstResponder(nil))
            if state == .pressed { button.highlight(true) }
            if state == .focused { try #require(window.makeFirstResponder(button)) }
            button.needsDisplay = true
            scene.content.layoutSubtreeIfNeeded()
            scene.state.layoutSubtreeIfNeeded()
            launch.layoutSubtreeIfNeeded()
            window.display()
            CATransaction.flush()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            window.display()
            #expect(button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
            #expect(button.title == originalTitle)
            #expect(button.accessibilityTitle() == originalAXTitle)
            #expect(button.cell?.isHighlighted == (state == .pressed))
            #expect((window.firstResponder === button) == (state == .focused))
            let host = scene.content
            let bitmap = try unwrap499(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let image = try unwrap499(bitmap.cgImage)
            let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
            let frame = host.convert(button.bounds, from: button)
            let crop = CGRect(x: frame.minX * scaleX, y: (host.bounds.height - frame.maxY) * scaleY,
                width: frame.width * scaleX, height: frame.height * scaleY).integral
            let buttonImage = try unwrap499(image.cropping(to: crop))
            let buttonBitmap = NSBitmapImageRep(cgImage: buttonImage)
            let tag = "\(step)-\(appearance.rawValue)-\(state.rawValue)"
            if let evidence {
                try unwrap499(bitmap.representation(using: .png, properties: [:]))
                    .write(to: evidence.appendingPathComponent("\(tag)-host.png"))
                try unwrap499(buttonBitmap.representation(using: .png, properties: [:]))
                    .write(to: evidence.appendingPathComponent("\(tag)-button.png"))
            }
            let interior = button.bounds.insetBy(dx: 7, dy: 5)
            let label = try unwrap499(button.cell).titleRect(forBounds: button.bounds)
                .intersection(interior).insetBy(dx: 1, dy: 1)
            let titlePixels = CGRect(x: label.minX * scaleX, y: (button.bounds.height - label.maxY) * scaleY,
                width: label.width * scaleX, height: label.height * scaleY).integral
            let fill = try unwrap499(buttonBitmap.colorAt(x: Int(10 * scaleX),
                y: buttonBitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            let base = [fill.redComponent, fill.greenComponent, fill.blueComponent]
            var opaque = 0, blue = 0, white = 0, dark = 0, offSegment = 0
            var whiteRows = Set<Int>(), whiteColumns = Set<Int>()
            for y in 0..<buttonBitmap.pixelsHigh {
                for x in 0..<buttonBitmap.pixelsWide {
                    let c = try unwrap499(buttonBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if c.alphaComponent > 0.95 { opaque += 1 }
                    if c.alphaComponent > 0.95 && c.blueComponent > 0.65 && c.blueComponent > c.redComponent + 0.3 {
                        blue += 1
                    }
                    if titlePixels.contains(CGPoint(x: x, y: y)) && c.alphaComponent > 0.95 {
                        if min(c.redComponent, c.greenComponent, c.blueComponent) >= 0.90 {
                            white += 1
                            whiteRows.insert(y)
                            whiteColumns.insert(x)
                        }
                        if max(c.redComponent, c.greenComponent, c.blueComponent) < 0.25 { dark += 1 }
                        let channels = [c.redComponent, c.greenComponent, c.blueComponent]
                        let distance = distance499(channels, from: base)
                        if distance > 0.10 { offSegment += 1 }
                    }
                }
            }
            print("i499 frame \(tag) key=\(window.isKeyWindow) active=\(NSApp.isActive) frame=\(button.frame) hostFrame=\(frame) raster=\(buttonBitmap.pixelsWide)x\(buttonBitmap.pixelsHigh) scale=\(scaleX),\(scaleY) title=\(titlePixels) opaque=\(opaque) blue=\(blue) white=\(white) dark=\(dark) offSegment=\(offSegment) fill=\(base) rows=\(whiteRows.count) cols=\(whiteColumns.count)")
            let expectedFill: [CGFloat]
            if appearance == NSAppearance.Name.darkAqua {
                expectedFill = [CGFloat(29) / CGFloat(255), CGFloat(78) / CGFloat(255), CGFloat(216) / CGFloat(255)]
            } else {
                expectedFill = [CGFloat(37) / CGFloat(255), CGFloat(99) / CGFloat(255), CGFloat(235) / CGFloat(255)]
            }
            var fillError: CGFloat = 0
            for index in base.indices {
                fillError = max(fillError, abs(base[index] - expectedFill[index]))
            }
            samples.append(Primary499Sample(opaque: opaque, blue: blue, white: white, dark: dark,
                rows: whiteRows.count, columns: whiteColumns.count, offSegment: offSegment,
                frame: button.frame, area: buttonBitmap.pixelsWide * buttonBitmap.pixelsHigh,
                fillError: fillError, state: state,
                active: NSApp.isActive, key: window.isKeyWindow))
        }
    }
    return samples
}

private func distance499(_ channels: [CGFloat], from base: [CGFloat]) -> CGFloat {
    let direction = base.map { 1 - $0 }
    var numerator: CGFloat = 0
    var denominator: CGFloat = 0
    for index in channels.indices {
        numerator += (channels[index] - base[index]) * direction[index]
        denominator += direction[index] * direction[index]
    }
    let fraction = min(1, max(0, numerator / denominator))
    var distance: CGFloat = 0
    for index in channels.indices {
        distance = max(distance, abs(channels[index] - base[index] - fraction * direction[index]))
    }
    return distance
}

private enum Primary499State: String, CaseIterable {
    case normal, pressed, focused
}

private struct Primary499Sample {
    let opaque: Int, blue: Int, white: Int, dark: Int
    let rows: Int, columns: Int, offSegment: Int
    let frame: NSRect
    let area: Int
    let fillError: CGFloat
    let state: Primary499State
    let active: Bool, key: Bool
}

private func unwrap499<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "i499-capture", code: 1) }
    return value
}

/// gui-lock.sh has no process-lifetime lease. The test therefore never acquires
/// or releases the shared lock; an opt-in caller owns cleanup even if this process dies.
private func validate499BorrowedGUILease() throws {
    let environment = ProcessInfo.processInfo.environment
    let owner = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/desktop-gui.lock/owner")
    guard let token = environment["PICSEE_I499_GUI_ACQUISITION"],
          UUID(uuidString: token) != nil,
          let ownerText = try? String(contentsOf: owner, encoding: .utf8) else {
        throw NSError(domain: "i499-gui-environment-precondition", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected a valid caller-owned picsee GUI lease before real-window rendering."])
    }
    let lines = ownerText.split(separator: "\n").map(String.init)
    guard lines.contains("project=picsee"), lines.contains("acquisition_id=\(token)") else {
        throw NSError(domain: "i499-gui-environment-precondition", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "PICSEE_I499_GUI_ACQUISITION does not match the current picsee GUI lease."])
    }
}
