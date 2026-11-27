import AppKit
import Testing

// #912 (from PR #909): a layout failure must leave measured geometry, not two bare heights, and a layout check must
// keep a margin so a local pass holds under small font-metric drift on the hosted runner.

@MainActor private func evidenceWindow(_ field: NSTextField, sibling: NSView) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(sibling)
    return window
}

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("issue912-\(UUID().uuidString)", isDirectory: true)
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue912FailedFitWritesBoundedGeometryRecordAndImage() throws {
    let long = String(repeating: "还没有密钥？ No key yet? ", count: 60)
    let field = NSTextField(labelWithString: long)
    field.frame = NSRect(x: 20, y: 40, width: 60, height: 17)
    field.font = NSFont.systemFont(ofSize: 13)
    field.setAccessibilityIdentifier("issue912.label")
    let sibling = NSButton(title: "OK", target: nil, action: nil)
    sibling.frame = NSRect(x: 100, y: 40, width: 60, height: 24)
    sibling.setAccessibilityIdentifier("issue912.sibling")
    let window = evidenceWindow(field, sibling: sibling)
    defer { window.close() }
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let measure = layoutLabelMeasure(long, font: field.font!, frame: field.frame.size)
    #expect(!measure.fits)

    let url = try #require(recordLayoutFailure(test: "issue912 probe()", view: field, shown: long, locale: "zh-Hans",
                                               measure: measure, directory: directory))
    let record = try #require(FileManager.default.contents(atPath: url.path)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
    #expect(record["view"] as? String == "issue912.label")
    #expect(record["locale"] as? String == "zh-Hans")
    #expect((record["shown"] as? String)?.count == LayoutFit.maxText, "shown text is bounded")
    #expect((record["font"] as? [String: Any])?["name"] as? String == field.font!.fontName)
    #expect((record["font"] as? [String: Any])?["size"] as? Double == 13)
    #expect((record["frame"] as? [String: Double])?["width"] == 60)
    #expect((record["required"] as? [String: Double])?["height"] == Double(measure.required.height))
    #expect((record["available"] as? [String: Double])?["height"] == 18)
    let siblings = try #require(record["siblings"] as? [[String: Any]])
    #expect(siblings.contains { $0["view"] as? String == "issue912.sibling" })
    for key in ["os", "xcode", "image", "fingerprint"] {
        #expect(!((record[key] as? String) ?? "").isEmpty, "\(key) missing")
    }
    #expect((record["window"] as? [String: Any])?["backingScale"] != nil)
    let image = try #require(record["image"] as? String)
    #expect(!image.hasPrefix("capture unavailable"), "\(image)")
    let png = try #require(NSImage(contentsOf: directory.appendingPathComponent(image)))
    #expect(png.size.width > field.frame.width && png.size.width <= 240)
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue912DetachedViewSaysCaptureUnavailable() throws {
    let field = NSTextField(labelWithString: "Detached")
    field.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try #require(recordLayoutFailure(test: "issue912 detached()", view: field, shown: "Detached", locale: "en",
                                               measure: LayoutMeasure(required: NSSize(width: 50, height: 17),
                                                                      available: NSSize(width: 10, height: 11)),
                                               directory: directory))
    let record = try #require(FileManager.default.contents(atPath: url.path)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
    #expect((record["image"] as? String)?.hasPrefix("capture unavailable: ") == true)
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue912MetricsFingerprintIsOneLineWithMeasuredWidths() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let line = emitLayoutMetricsFingerprint(directory: directory, printLine: false)
    #expect(!line.contains("\n"))
    let pattern = #/^layout-metrics-fingerprint: os=.+ xcode=.+ image=.+ system=\S+ zh-fallback=\S+ en11=(\d+\.\d\d) zh11=(\d+\.\d\d) en13=(\d+\.\d\d) zh13=(\d+\.\d\d) margin=\S+$/#
    let match = try #require(line.wholeMatch(of: pattern), "\(line)")
    #expect(Double(match.output.1)! > 0 && Double(match.output.4)! > Double(match.output.2)!)
    // Read without throwing: a missing file is an assertion failure here, not an error text.
    let written = FileManager.default.contents(atPath: directory.appendingPathComponent("fingerprint.txt").path)
    #expect(written.flatMap { String(data: $0, encoding: .utf8) } == line + "\n")
}

// #672: the time-limit policy needs a limit on every AppKit test; the suite gives the tests below one.
@Suite(.timeLimit(.minutes(1))) struct Issue912LayoutFitTimed {
@Test func issue912ButtonFitNeedsMarginOverTheTitle() {
    // Title 80 pt in a control whose bezel adds 20 pt: at a 5% margin an exact 100 pt frame (+1 pt slack) no longer passes.
    #expect(!layoutButtonMeasure(intrinsicWidth: 100, textWidth: 80, frame: NSSize(width: 100, height: 22), margin: 1.05).fits)
    #expect(layoutButtonMeasure(intrinsicWidth: 100, textWidth: 80, frame: NSSize(width: 104, height: 22), margin: 1.05).fits)
    #expect(layoutButtonMeasure(intrinsicWidth: 100, textWidth: 80, frame: NSSize(width: 100, height: 22), margin: 1).fits)
}

@Test func issue912DefaultMarginRejectsTheHostedFailureOfPR909() {
    // #909 fix 4: 还没有密钥？ measured 65.67 pt locally in a frame sized for "No key yet?" (65.87 pt); hosted CI wrapped it.
    let hosted909 = layoutButtonMeasure(intrinsicWidth: 65.67, textWidth: 65.67, frame: NSSize(width: 64.87, height: 17))
    #expect(!hosted909.fits, "the default margin must reject a 0.3% fit")
    #expect(layoutButtonMeasure(intrinsicWidth: 65.67, textWidth: 65.67, frame: NSSize(width: 64.87, height: 17), margin: 1).fits)
    #expect(LayoutFit.margin > 1.003)
}

@MainActor @Test func issue912LabelFitNeedsMarginOverTheLine() {
    let font = NSFont.systemFont(ofSize: 13)
    let text = "No key yet? 还没有密钥？"
    let width = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 1
    let frame = NSSize(width: width, height: 17)
    #expect(layoutLabelMeasure(text, font: font, frame: frame, margin: 1).fits, "exact fit without a margin")
    #expect(!layoutLabelMeasure(text, font: font, frame: frame, margin: 1.05).fits, "an exact one-line fit wraps under a margin")
}

@MainActor @Test(.timeLimit(.minutes(1))) func issue912SharedAssertionNamesTheMeasuredNumbers() throws {
    let field = NSTextField(labelWithString: "Too long for ten points")
    field.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
    field.setAccessibilityIdentifier("issue912.shared")
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failing = LayoutMeasure(required: NSSize(width: 50, height: 17), available: NSSize(width: 10, height: 11))
    let message = try #require(layoutFailureMessage(failing, view: field, shown: "Too long for ten points", locale: "en",
                                                    test: "issue912 shared()", directory: directory))
    #expect(message.contains("view=issue912.shared") && message.contains("required=") && message.contains("available="))
    #expect(message.contains("evidence=\(directory.path)"), "\(message)")
    #expect(layoutFailureMessage(LayoutMeasure(required: .zero, available: NSSize(width: 1, height: 1)), view: field,
                                 shown: "x", locale: "en", test: "issue912 fits()", directory: directory) == nil)
}

// The run's one fingerprint line (local and hosted): printed to the log and written to .build/layout-evidence.
@MainActor @Test func issue912PrintsTheMetricsFingerprintForThisRun() {
    let line = emitLayoutMetricsFingerprint()
    let written = FileManager.default.contents(atPath: layoutEvidenceDirectory().appendingPathComponent("fingerprint.txt").path)
    #expect(written.flatMap { String(data: $0, encoding: .utf8) } == line + "\n")
}
}
