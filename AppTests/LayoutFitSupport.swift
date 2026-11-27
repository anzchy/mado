import AppKit
import Testing

// #912: shared fit-with-margin check for App layout tests, plus the evidence a failure leaves behind.
//
// PR #909 failed on the hosted runner only: a zh-Hans label wrapped there but fitted on the Mac mini, and the failure
// line carried two heights and nothing else. Two rules follow (mado-verify §3):
// - a layout test requires headroom, not an exact fit: the measured text times `LayoutFit.margin` must fit, so a local
//   pass still holds under small font-metric drift between machines;
// - a failed fit writes a bounded JSON record and a cropped image of the control's neighbourhood to
//   `layoutEvidenceDirectory()` (`.build/layout-evidence`, which CI uploads in `app-crash-evidence`).
// Real fonts stay: the check measures with the control's own font, it never substitutes one.

enum LayoutFit {
    /// One reviewed number for every layout test. 1.005 is the largest margin today's Settings panel passes on the
    /// Mac mini (macOS 26.4 25E246, measured 2026-11-26: three English switch titles have 0.5% headroom), and it rejects
    /// PR #909's hosted failure (a 65.67 pt zh-Hans line in a 65.87 pt frame, ratio 1.003). Raising it needs wider
    /// controls first (#912 handoff lists them); hosted `layout-metrics-fingerprint:` lines show how much drift is real.
    static let margin: CGFloat = 1.005
    /// Upper bound on records per test process, so a broken pane cannot fill the artifact.
    static let maxRecords = 24
    /// Longest shown text kept in a record.
    static let maxText = 300
}

struct LayoutMeasure: Equatable {
    var required: NSSize
    var available: NSSize
    var fits: Bool { required.width <= available.width && required.height <= available.height }
}

/// A single-line control (button) fits when its title, widened by the margin, plus the control's own inset fits the frame.
func layoutButtonMeasure(intrinsicWidth: CGFloat, textWidth: CGFloat, frame: NSSize,
                         margin: CGFloat = LayoutFit.margin) -> LayoutMeasure {
    let inset = max(0, intrinsicWidth - textWidth)
    return LayoutMeasure(required: NSSize(width: textWidth * margin + inset, height: 0),
                         available: NSSize(width: frame.width + 1, height: 0))
}

/// A wrapping label fits when the text, laid out in the frame's width divided by the margin, is no taller than the frame.
@MainActor func layoutLabelMeasure(_ text: String, font: NSFont, frame: NSSize,
                                   margin: CGFloat = LayoutFit.margin) -> LayoutMeasure {
    let width = frame.width / margin
    let size = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                               attributes: [.font: font]).size
    return LayoutMeasure(required: NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up)),
                         available: NSSize(width: frame.width, height: frame.height + 1))
}

/// The directory a layout failure writes to. `MADO_LAYOUT_EVIDENCE_DIR` overrides; otherwise `<repo>/.build/layout-evidence`.
func layoutEvidenceDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let path = environment["MADO_LAYOUT_EVIDENCE_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/layout-evidence", isDirectory: true)
}

private final class LayoutEvidenceAnchor {}

/// Machine identity for a record: OS build, Xcode build of this test bundle, runner image (GitHub sets ImageOS/ImageVersion).
func layoutEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    let info = Bundle(for: LayoutEvidenceAnchor.self).infoDictionary ?? [:]
    let xcode = [info["DTXcode"] as? String, info["DTXcodeBuild"] as? String].compactMap { $0 }.joined(separator: " ")
    let image = [environment["ImageOS"], environment["ImageVersion"]].compactMap { $0 }.joined(separator: " ")
    return ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "xcode": xcode.isEmpty ? "unknown" : xcode,
            "image": image.isEmpty ? "local (no ImageOS/ImageVersion)" : image]
}

/// One line per run that names the text metrics this machine produces, so "font metrics differ" can be checked.
@MainActor func layoutMetricsFingerprint(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    func width(_ text: String, _ size: CGFloat) -> String {
        String(format: "%.2f", (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
    }
    let en = "No key yet?", zh = "还没有密钥？"
    let fallback = CTFontCreateForString(NSFont.systemFont(ofSize: 13) as CTFont, zh as CFString,
                                         CFRange(location: 0, length: (zh as NSString).length))
    let machine = layoutEnvironment(environment: environment)
    return "layout-metrics-fingerprint: os=\(machine["os"]!) xcode=\(machine["xcode"]!) image=\(machine["image"]!) " +
        "system=\(NSFont.systemFont(ofSize: 13).fontName) zh-fallback=\(CTFontCopyPostScriptName(fallback) as String) " +
        "en11=\(width(en, 11)) zh11=\(width(zh, 11)) en13=\(width(en, 13)) zh13=\(width(zh, 13)) margin=\(LayoutFit.margin)"
}

/// Prints the fingerprint line and writes it to `<directory>/fingerprint.txt`, so retained `xcrun xctest` runs export it too.
@MainActor @discardableResult
func emitLayoutMetricsFingerprint(directory: URL = layoutEvidenceDirectory(), printLine: Bool = true) -> String {
    let line = layoutMetricsFingerprint()
    if printLine { print(line) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? (line + "\n").write(to: directory.appendingPathComponent("fingerprint.txt"), atomically: true, encoding: .utf8)
    return line
}

@MainActor private var layoutRecordCount = 0

/// Writes `<test>-<n>.json` (and `<test>-<n>.png` when the view can be drawn) for one failed fit. Returns the JSON URL,
/// or nil once `LayoutFit.maxRecords` records exist. The JSON says `capture unavailable: <reason>` when no image was made.
@MainActor @discardableResult
func recordLayoutFailure(test: String, view: NSView, shown: String, locale: String, measure: LayoutMeasure,
                         directory: URL = layoutEvidenceDirectory()) -> URL? {
    guard layoutRecordCount < LayoutFit.maxRecords else { return nil }
    layoutRecordCount += 1
    let slug = test.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    let base = "\(slug)-\(layoutRecordCount)"
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func rect(_ r: NSRect) -> [String: Double] {
        ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
    }
    func name(_ v: NSView) -> String {
        let id = v.accessibilityIdentifier()
        return id.isEmpty ? String(describing: type(of: v)) : id
    }
    let font = (view as? NSControl)?.font
    let siblings = (view.superview?.subviews ?? []).filter { $0 !== view && !$0.isHidden }.prefix(16).map {
        ["view": name($0), "frame": rect($0.frame)] as [String: Any]
    }
    var image = "capture unavailable: view has no window or zero size"
    if let container = view.superview, view.window != nil {
        let crop = view.frame.insetBy(dx: -24, dy: -12).intersection(container.bounds)
        if !crop.isEmpty, let rep = container.bitmapImageRepForCachingDisplay(in: crop) {
            container.cacheDisplay(in: crop, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let file = directory.appendingPathComponent("\(base).png")
                do { try png.write(to: file); image = file.lastPathComponent }
                catch { image = "capture unavailable: \(error.localizedDescription)" }
            } else { image = "capture unavailable: PNG encoding failed" }
        }
    }
    var record: [String: Any] = [
        "version": 1, "test": test, "view": name(view), "class": String(describing: type(of: view)),
        "shown": String(shown.prefix(LayoutFit.maxText)), "locale": locale,
        "font": ["name": font?.fontName ?? "unknown", "size": Double(font?.pointSize ?? 0)],
        "frame": rect(view.frame), "windowFrame": rect(view.convert(view.bounds, to: nil)),
        "required": ["width": Double(measure.required.width), "height": Double(measure.required.height)],
        "available": ["width": Double(measure.available.width), "height": Double(measure.available.height)],
        "margin": Double(LayoutFit.margin), "siblings": Array(siblings), "image": image,
        "fingerprint": layoutMetricsFingerprint()]
    record.merge(layoutEnvironment()) { current, _ in current }
    if let window = view.window {
        record["window"] = ["size": rect(window.frame), "backingScale": Double(window.backingScaleFactor),
                            "appearance": window.effectiveAppearance.name.rawValue]
    }
    let file = directory.appendingPathComponent("\(base).json")
    // A NaN or infinite number makes JSONSerialization raise an Objective-C exception that `try?` cannot catch and that
    // would end the test process, so an unencodable record is not written (the issue text still names the numbers).
    guard JSONSerialization.isValidJSONObject(record),
          let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]),
          (try? data.write(to: file)) != nil else { return nil }
    return file
}

/// The shared assertion: records an issue that names the measured numbers, and leaves the evidence files.
@MainActor func expectLayoutFits(_ measure: LayoutMeasure, view: NSView, shown: String, locale: String,
                                 test: String, directory: URL = layoutEvidenceDirectory(),
                                 sourceLocation: SourceLocation = #_sourceLocation) {
    guard let message = layoutFailureMessage(measure, view: view, shown: shown, locale: locale, test: test,
                                             directory: directory) else { return }
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// nil when the measure fits; otherwise writes the evidence and returns the issue text with the measured numbers.
@MainActor func layoutFailureMessage(_ measure: LayoutMeasure, view: NSView, shown: String, locale: String,
                                     test: String, directory: URL = layoutEvidenceDirectory()) -> String? {
    guard !measure.fits else { return nil }
    let record = recordLayoutFailure(test: test, view: view, shown: shown, locale: locale, measure: measure,
                                     directory: directory)
    let font = (view as? NSControl)?.font?.fontName ?? "unknown"
    return "\(locale) does not fit with margin \(LayoutFit.margin): \(shown) view=\(view.accessibilityIdentifier()) " +
        "required=\(measure.required) available=\(measure.available) font=\(font) " +
        "evidence=\(record?.path ?? "not written")"
}
