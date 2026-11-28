import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #870 (EXT-06 T12, spec #866, state 35 settings.html as of PR #883): the 截图 page keeps one short hint per row.
// The long Capture Bar, Screen Recording and 文字识别 (Baidu) text moves to the help site (site/), reached by a
// 「了解更多 ↗」 link that hands the page to the default browser through the Settings URL-open seam. Measured at the
// Settings pane's only size (580 pt, it does not resize) with the real fonts, in both languages and appearances.

private actor BarOff870: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool { false }
    func setCaptureBarEnabled(_ enabled: Bool) {}
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

@MainActor private final class Opened870 { var urls: [URL] = [] }

@MainActor private struct Fixture870 {
    let panel: SettingsPanelWindow
    let opened: Opened870

    init(_ locale: String, dark: Bool = false) throws {
        let catalog = try captureCatalog(locale)
        let opened = Opened870()
        let display = InMemoryDisplayPreferencesStore()
        panel = SettingsPanelWindow(
            cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            appearanceAdapter: WindowAppearanceAdapter(preferencesStore: display), preferencesStore: display,
            defaults: UserDefaults(suiteName: "issue870-\(UUID().uuidString)")!,
            capturePreferences: BarOff870(), captureLocalize: { catalog[$0] ?? $0 },
            cloudRecognition: .inMemory(),
            openURL: { opened.urls.append($0) })
        panel.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.select(.capture)
        self.opened = opened
    }

    func find(_ id: String) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        return panel.window.contentView.flatMap(search)
    }

    func view<T: NSView>(_ id: String, as type: T.Type = NSView.self) throws -> T {
        try #require(find(id) as? T, "\(id)")
    }

    func click(_ id: String) throws {
        let control = try view(id, as: NSControl.self)
        control.sendAction(control.action, to: control.target)
    }
}

/// Lines the label's text takes in its own frame width (the cell's own layout, so the drawing inset counts).
@MainActor private func lineCount(_ field: NSTextField) -> Int {
    let height = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width,
                                                        height: .greatestFiniteMagnitude)).height
    let line = NSLayoutManager().defaultLineHeight(for: field.font!)
    return Int((height / line).rounded())
}

/// The link sits beside the first line of its hint, inside the value column, and the hint is not clipped.
@MainActor private func expectLinkBesideHint(_ hint: NSTextField, _ link: NSButton, maxX: CGFloat, maxLines: Int,
                                             locale: String, test: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(hint.superview === link.superview, "\(locale) link and hint share a container", sourceLocation: sourceLocation)
    #expect(hint.frame.maxX + 6 <= link.frame.minX + 0.5, "\(locale) link starts after its hint", sourceLocation: sourceLocation)
    #expect(link.frame.maxX <= maxX + 0.5, "\(locale) link stays inside the value column", sourceLocation: sourceLocation)
    let firstLineTop = hint.superview!.isFlipped ? hint.frame.minY : hint.frame.maxY
    let linkTop = link.superview!.isFlipped ? link.frame.minY : link.frame.maxY
    #expect(abs(firstLineTop - linkTop) < 1.5, "\(locale) link is level with the hint's first line", sourceLocation: sourceLocation)
    let title = link.attributedTitle.size().width
    expectLayoutFits(layoutButtonMeasure(intrinsicWidth: link.intrinsicContentSize.width, textWidth: title,
                                         frame: link.frame.size),
                     view: link, shown: link.title, locale: locale, test: "\(test)-link", sourceLocation: sourceLocation)
    expectLayoutFits(layoutLabelMeasure(hint.stringValue, font: hint.font!, frame: hint.frame.size),
                     view: hint, shown: hint.stringValue, locale: locale, test: test, sourceLocation: sourceLocation)
    #expect(lineCount(hint) <= maxLines, "\(locale) \(hint.stringValue) takes \(lineCount(hint)) lines",
            sourceLocation: sourceLocation)
}

private let barHint = [
    "zh-Hans": "打开后，没有 Mado 窗口也能截图；第一次需要允许「录屏与系统录音」权限。",
    "en": "Captures without a Mado window; first allow Screen & System Audio Recording."
]
private let macOS15Hint = [
    "zh-Hans": "macOS 15 起，系统会不定期再问一次，选「允许」即可。",
    "en": "macOS 15 and later ask again at times; choose Allow."
]
private let keysHint = [
    "zh-Hans": "访问密钥保存在 macOS 钥匙串中。",
    "en": "Keys are kept in the macOS Keychain."
]
private let learnMore = ["zh-Hans": "了解更多 ↗", "en": "Learn More ↗"]

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"], [false, true])
func issue870CaptureBarHintIsShortWithScreenRecordingHelpLink(_ locale: String, dark: Bool) throws {
    let f = try Fixture870(locale, dark: dark)
    defer { f.panel.window.close() }
    let hint = try f.view("settings.capture.privacy-hint", as: NSTextField.self)
    let link = try f.view("settings.capture.bar-learn", as: NSButton.self)
    #expect(hint.stringValue == barHint[locale])
    #expect(link.title == learnMore[locale])
    #expect(link.accessibilityRole() == .link)
    // State 35's own sentence is wider than the value column (zh 409 pt in 384 pt), so it takes two lines; see handoff.
    expectLinkBesideHint(hint, link, maxX: 554, maxLines: 2, locale: locale, test: "i870-bar-hint")
    // The 登录时启动 row below keeps its place: the hint does not run into it.
    let login = try f.view("settings.capture.login")
    #expect(hint.frame.minY >= login.frame.maxY + 4, "\(locale) bar hint overlaps 登录时启动")
    try f.click("settings.capture.bar-learn")
    #expect(f.opened.urls == [URL(string: "https://anzchy.github.io/mado/screen-recording.html")!])
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"], [false, true])
func issue870ScreenRecordingNoteIsOneLine(_ locale: String, dark: Bool) throws {
    let f = try Fixture870(locale, dark: dark)
    defer { f.panel.window.close() }
    let note = try f.view("settings.capture.permission-note", as: NSTextField.self)
    #expect(note.stringValue == macOS15Hint[locale])
    expectLayoutFits(layoutLabelMeasure(note.stringValue, font: note.font!, frame: NSSize(width: note.frame.width,
                                                                                            height: 18)),
                     view: note, shown: note.stringValue, locale: locale, test: "i870-macos15-note")
    #expect(lineCount(note) == 1, "\(locale) macOS 15 note takes \(lineCount(note)) lines")
    let status = try f.view("settings.capture.permission-status")
    let after = try f.view("settings.capture.heading-after")
    #expect(note.frame.maxY <= status.frame.minY + 0.5 && note.frame.minY > after.frame.maxY)
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"], [false, true])
func issue870TextRecognitionKeepsOnlyShortLinesAndLinksBaiduHelp(_ locale: String, dark: Bool) throws {
    let f = try Fixture870(locale, dark: dark)
    defer { f.panel.window.close() }
    // The long disclosure, the Baidu product sentence and the terms link move to the help page.
    for id in ["settings.capture.ocr-hint", "settings.capture.ocr-product-hint", "settings.capture.ocr-terms"] {
        #expect(f.find(id) == nil, "\(id) is gone from Settings")
    }
    let group = try f.view("settings.capture.ocr")
    let hint = try f.view("settings.capture.ocr-keys-hint", as: NSTextField.self)
    let link = try f.view("settings.capture.ocr-learn", as: NSButton.self)
    #expect(hint.stringValue == keysHint[locale])
    #expect(link.title == learnMore[locale])
    #expect(link.accessibilityRole() == .link)
    expectLinkBesideHint(hint, link, maxX: group.frame.width, maxLines: 1, locale: locale, test: "i870-keys-hint")
    // Service row sits directly above the keys row now; nothing in the group overlaps.
    let service = try f.view("settings.capture.ocr-service")
    let api = try f.view("settings.capture.ocr-api-key")
    #expect(api.frame.minY - service.frame.maxY <= 12, "\(locale) keys row follows the service row")
    let visible = group.subviews.filter { !$0.isHidden && !($0 is NSBox) }
    for (index, a) in visible.enumerated() {
        for b in visible.dropFirst(index + 1) {
            #expect(!a.frame.intersects(b.frame), "\(a.accessibilityIdentifier()) overlaps \(b.accessibilityIdentifier())")
        }
    }
    try f.click("settings.capture.ocr-learn")
    #expect(f.opened.urls == [URL(string: "https://anzchy.github.io/mado/baidu-key.html")!])
}

/// AC 1: what left Settings is on the help page its link opens (site/ is the GitHub Pages source).
@MainActor @Test(.timeLimit(.minutes(3)))
func issue870RemovedDetailLivesOnTheLinkedHelpPages() throws {
    let site = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("site")
    func page(_ name: String) throws -> String {
        try String(contentsOf: site.appendingPathComponent(name), encoding: .utf8)
    }
    let recording = try page("screen-recording.html")
    for phrase in ["录屏与系统录音", "截图助手", "关闭", "macOS 15", "这是系统要求"] {
        #expect(recording.contains(phrase), "screen-recording.html says \(phrase)")
    }
    let baidu = try page("baidu-key.html")
    for phrase in ["实名认证", "中国大陆证件", "保存多久", "通用文字识别", "钥匙串",
                   "https://ai.baidu.com/ai-doc/REFERENCE/kk3dwjg7d"] {
        #expect(baidu.contains(phrase), "baidu-key.html says \(phrase)")
    }
    let cloud = try page("cloud-recognition.html")
    for phrase in ["识别文字", "识别表格", "同意", "本机识别"] {
        #expect(cloud.contains(phrase), "cloud-recognition.html says \(phrase)")
    }
}

/// AC 3: the consent dialog, where the user decides, still carries ADR-019's Baidu disclosure and terms link.
@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["zh-Hans", "en"])
func issue870ConsentDialogStillCarriesTheBaiduDisclosure(_ locale: String) throws {
    let catalog = try captureCatalog(locale)
    let alert = CloudRecognitionSettingsGroup.consentAlert(localize: { catalog[$0] ?? $0 }, openURL: { _ in })
    let text = alert.informativeText
    if locale == "zh-Hans" {
        for phrase in ["百度", "实名认证", "中国大陆证件", "保存图片的期限", "服务条款"] { #expect(text.contains(phrase), "\(phrase)") }
    } else {
        for phrase in ["Baidu", "real-name verification", "mainland Chinese ID", "How long Baidu keeps images"] {
            #expect(text.contains(phrase), "\(phrase)")
        }
    }
    #expect(alert.accessoryView is NSButton)
}
