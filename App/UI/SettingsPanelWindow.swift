import AppKit
import MadoApplication
import MadoInfrastructure
import MadoMacUI

enum SettingsSection: String, CaseIterable {
    case general, display, cache, capture, update, about
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .display: String(localized: "Display")
        case .cache: String(localized: "Cache")
        case .capture: String(localized: "Screenshots")
        case .update: String(localized: "Updates")
        case .about: String(localized: "About")
        }
    }
}

actor AppGroupCaptureBarPreferences: CaptureBarPreferencePort {
    private let defaults = UserDefaults(suiteName: CaptureBarIdentity.appGroupID)

    func isCaptureBarEnabled() -> Bool {
        defaults?.bool(forKey: CaptureBarIdentity.enabledKey) == true
    }

    func setCaptureBarEnabled(_ enabled: Bool) {
        defaults?.set(enabled, forKey: CaptureBarIdentity.enabledKey)
        defaults?.synchronize()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(CaptureBarIdentity.switchChangedNotification as CFString), nil, nil, true)
    }

    func capturePermissionState() -> CapturePermissionState? {
        defaults?.string(forKey: CaptureBarIdentity.permissionKey).flatMap(CapturePermissionState.init(rawValue:))
    }
}

@MainActor private final class WorkspaceCaptureBarProcess: CaptureBarProcessPort {
    enum Failure: Error { case helperMissing, didNotExit }

    func startCaptureBar() async throws {
        let url = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LoginItems/MadoCaptureHelper.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.helperMissing }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func stopCaptureBar() async throws {
        // The shared-switch notification asks the helper to exit itself; process APIs are a fallback.
        for _ in 0..<20 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: CaptureBarIdentity.bundleID).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CaptureBarIdentity.bundleID)
        for app in apps { _ = app.terminate() }
        for _ in 0..<50 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: CaptureBarIdentity.bundleID).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let survivors = NSRunningApplication.runningApplications(withBundleIdentifier: CaptureBarIdentity.bundleID)
        for app in survivors { _ = app.forceTerminate() }
        for _ in 0..<20 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: CaptureBarIdentity.bundleID).isEmpty { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.didNotExit
    }
}

@MainActor final class SettingsPanelWindow: NSObject, DisplayPreferencesObserver {
    private static let sectionKey = "settings.selectedSection.v1"

    static let sharedCapturePreferences = AppGroupCaptureBarPreferences()
    static let sharedCaptureControl = CaptureBarControl(preferences: sharedCapturePreferences,
                                                        process: WorkspaceCaptureBarProcess())
    static func restoreCaptureBarOnLaunch() async throws { try await sharedCaptureControl.restoreOnMadoLaunch() }
    let window: NSWindow
    private(set) var selectedSection: SettingsSection
    private let appearanceAdapter: WindowAppearanceAdapter
    private let preferencesStore: any DisplayPreferencesStore
    private let defaults: UserDefaults
    private let model: CacheSettingsModel
    private let confirmClear: (NSWindow, @escaping (Bool) -> Void) -> Void
    private let openURL: (URL) -> Void
    private let aboutInfoDictionary: [String: Any]?
    private let aboutLocalizedString: (String) -> String
    private let updates: (any AppUpdatePort)?
    private var panes: [SettingsSection: NSView] = [:]
    private var sidebarButtons: [SettingsSection: NSButton] = [:]
    private var appearanceButtons: [DisplayAppearance: NSButton] = [:]
    private var entryPoints: [ObjectIdentifier: EntryPoint] = [:]
    private var toolsButton: NSButton!
    private var displaySize: NSSlider!
    private var toolOpacity: NSSlider!
    private var toolOpacityValue: NSTextField!
    private var displayNames: NSButton!
    private var fitButtons: [ThumbnailFit: NSButton] = [:]
    private var cacheSize: NSTextField!
    private var cacheDiagnostic: NSTextField!
    private var cacheClear: NSButton!
    private var updateVersion: NSTextField!
    private var updateAutomatic: NSButton!
    private var updateCheck: NSButton!
    private var updateLastChecked: NSTextField!
    private var captureEnabled: NSSwitch!
    private var captureDetails: [NSView] = []
    private let captureControl: CaptureBarControl
    private let capturePreferences: any CaptureBarPreferencePort
    private var capturePermissionStatus: NSTextField?
    private let captureLocalize: (String) -> String
    private var captureRefreshID = 0

    init(cache: ThumbnailDiskCache, appearanceAdapter: WindowAppearanceAdapter,
         preferencesStore: any DisplayPreferencesStore, defaults: UserDefaults,
         updates: (any AppUpdatePort)? = nil,
         captureControl: CaptureBarControl? = nil,
         capturePreferences: (any CaptureBarPreferencePort)? = nil,
         captureLocalize: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) },
         confirmClear: ((NSWindow, @escaping (Bool) -> Void) -> Void)? = nil,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         aboutInfoDictionary: [String: Any]? = nil,
         aboutLocalizedString: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) }) {
        self.appearanceAdapter = appearanceAdapter
        self.preferencesStore = preferencesStore
        self.defaults = defaults
        self.model = CacheSettingsModel(cache: cache)
        self.selectedSection = SettingsSection(rawValue: defaults.string(forKey: Self.sectionKey) ?? "") ?? .general
        self.confirmClear = confirmClear ?? Self.presentClearConfirmation
        self.openURL = openURL
        self.aboutInfoDictionary = aboutInfoDictionary
        self.aboutLocalizedString = aboutLocalizedString
        self.updates = updates
        self.captureControl = captureControl ?? Self.sharedCaptureControl
        self.capturePreferences = capturePreferences ?? Self.sharedCapturePreferences
        self.captureLocalize = captureLocalize
        self.window = SettingsPanelNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 482),
                                                styleMask: [.titled, .closable, .miniaturizable],
                                                backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.center()
        buildViews()
        preferencesStore.observe(self)
        updates?.observe { [weak self] in self?.refreshUpdates() }
        preferencesDidChange(preferencesStore.value)
        select(selectedSection)
    }

    func show() {
        appearanceAdapter.register(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshCache()
        if selectedSection == .capture { refreshCapture() }
    }

    func select(_ section: SettingsSection) {
        selectedSection = section
        defaults.set(section.rawValue, forKey: Self.sectionKey)
        window.title = section.title
        for (key, pane) in panes { pane.isHidden = key != section }
        for (key, button) in sidebarButtons {
            button.state = key == section ? .on : .off
            button.setAccessibilityValue(key == section ? "1" : "0")
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: DesignMetrics.font("ui"),
                .foregroundColor: key == section ? DesignColor.selectionText.nsColor : DesignColor.textPrimary.nsColor
            ])
            button.contentTintColor = key == section ? DesignColor.selectionText.nsColor : DesignColor.textSecondary.nsColor
            button.needsDisplay = true
        }
        if section == .cache { refreshCache() }
        if section == .update { refreshUpdates() }
        if section == .capture { refreshCapture() }
    }

    func preferencesDidChange(_ preferences: DisplayPreferences) {
        for (appearance, button) in appearanceButtons {
            button.state = appearance == preferences.appearance ? .on : .off
            button.setAccessibilityValue(appearance == preferences.appearance ? "1" : "0")
        }
        toolsButton.state = preferences.alwaysShowTools ? .on : .off
        displaySize.doubleValue = preferences.thumbnailSize
        toolOpacity.doubleValue = preferences.toolBackgroundOpacity
        toolOpacityValue.stringValue = ToolBackgroundOpacitySlider.percentage(preferences.toolBackgroundOpacity)
        displayNames.state = preferences.showFileNames ? .on : .off
        for (fit, button) in fitButtons {
            button.state = fit == preferences.thumbnailFit ? .on : .off
            button.setAccessibilityValue(fit == preferences.thumbnailFit ? "1" : "0")
        }
    }

    private func buildViews() {
        let root = SettingsSurfaceView(frame: NSRect(x: 0, y: 0, width: 760, height: 482), surface: .panel)
        let sidebar = SettingsSurfaceView(frame: NSRect(x: 0, y: 0, width: 180, height: 482), surface: .sidebar)
        sidebar.setAccessibilityIdentifier("settings.sidebar")
        root.addSubview(sidebar)
        let content = NSView(frame: NSRect(x: 180, y: 0, width: 580, height: 482))
        content.setAccessibilityIdentifier("settings.content")
        root.addSubview(content)
        for (index, section) in SettingsSection.allCases.enumerated() {
            let button = SettingsSidebarButton(title: section.title, target: self, action: #selector(selectSidebar(_:)))
            button.frame = NSRect(x: 8, y: 442 - CGFloat(index * 32), width: 164, height: 30)
            button.tag = index
            button.isBordered = false
            button.setButtonType(.toggle)
            button.alignment = .left
            button.font = DesignMetrics.font("ui")
            let symbols = ["gearshape", "rectangle.3.group", "externaldrive", "camera.viewfinder", "arrow.triangle.2.circlepath", "info.circle"]
            button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.setAccessibilityIdentifier("settings.section.\(section.rawValue)")
            sidebar.addSubview(button)
            sidebarButtons[section] = button
            let pane = NSView(frame: content.bounds)
            pane.setAccessibilityIdentifier("settings.pane.\(section.rawValue)")
            content.addSubview(pane)
            panes[section] = pane
            let heading = label(section.title, role: "title", bold: true)
            heading.frame = NSRect(x: 26, y: 444, width: 528, height: 20)
            pane.addSubview(heading)
        }
        buildGeneral()
        buildDisplay()
        buildCache()
        buildCapture()
        buildUpdates()
        buildAbout()
        window.contentView = root
    }

    private func label(_ text: String, role: String = "ui", bold: Bool = false, muted: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        let font = DesignMetrics.font(role)
        field.font = bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        field.textColor = muted ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    private func rowLabel(_ text: String, y: CGFloat, in pane: NSView) {
        let field = label(text)
        field.alignment = .right
        field.frame = NSRect(x: 26, y: y, width: 120, height: 24)
        pane.addSubview(field)
    }

    private func buildCapture() {
        let pane = panes[.capture]!
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 420))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier("settings.capture.scroll")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 1124))
        let captureLabels = ["Capture Bar", "Start at Login", "Screen Recording", "Capture Folder",
                             "Save to Folder", "Copy to Clipboard", "Capture and Recognize Text",
                             "Show / Hide Capture Bar", "Cloud Recognition"]
        let labelWidth = max(120, captureLabels.map {
            (captureLocalize($0) as NSString)
                .size(withAttributes: [.font: DesignMetrics.font("uiSmall")]).width.rounded(.up)
        }.max() ?? 120)
        let valueX = 26 + labelWidth + 16
        scroll.documentView = form
        pane.addSubview(scroll)

        @discardableResult func field(_ text: String, top: CGFloat, height: CGFloat = 24, id: String? = nil,
                   labelColumn: Bool = false, muted: Bool = false) -> NSTextField {
            let result = label(text, role: "uiSmall", muted: muted)
            result.textColor = muted ? DesignColor.textSecondary.nsColor : DesignColor.textPrimary.nsColor
            result.frame = NSRect(x: labelColumn ? 26 : valueX, y: 1124 - top - height,
                                  width: labelColumn ? labelWidth : 554 - valueX, height: height)
            if labelColumn { result.alignment = .right }
            if let id { result.setAccessibilityIdentifier(id) }
            form.addSubview(result)
            if top >= 105 { captureDetails.append(result) }
            return result
        }
        func disabledButton(_ title: String, top: CGFloat, id: String, x: CGFloat? = nil, width: CGFloat = 140) {
            let button = NSButton(title: title, target: nil, action: nil)
            button.font = DesignMetrics.font("uiSmall")
            button.frame = NSRect(x: x ?? valueX, y: 1124 - top - 24,
                                  width: max(width, button.intrinsicContentSize.width + 12), height: 24)
            button.isEnabled = false
            button.alphaValue = 0.45
            button.setAccessibilityIdentifier(id)
            form.addSubview(button)
            captureDetails.append(button)
        }
        func heading(_ text: String, top: CGFloat, id: String, divider: Bool) {
            if divider {
                let line = NSBox(frame: NSRect(x: 26, y: 1124 - top + 14, width: 528, height: 1))
                line.boxType = .separator
                form.addSubview(line)
            }
            let title = field(text, top: top, height: 20, id: id, muted: true)
            title.frame.origin.x = 26
            title.frame.size.width = 528
            title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        }
        func disabledSwitch(_ title: String, top: CGFloat, id: String, on: Bool = false) {
            let toggle = NSSwitch(frame: NSRect(x: valueX, y: 1124 - top - 18, width: 32, height: 18))
            toggle.controlSize = .mini
            toggle.state = on ? .on : .off
            toggle.isEnabled = false
            toggle.alphaValue = 0.45
            toggle.setAccessibilityIdentifier(id)
            toggle.setAccessibilityLabel(title)
            form.addSubview(toggle)
            captureDetails.append(toggle)
            let caption = field(title, top: top - 1, id: "\(id).title")
            caption.frame.origin.x = valueX + 40
            caption.frame.size.width = 514 - valueX
        }
        heading(captureLocalize("Capture Bar"), top: 10, id: "settings.capture.heading-bar", divider: false)
        field(captureLocalize("Capture Bar"), top: 50, labelColumn: true)
        captureEnabled = NSSwitch(frame: NSRect(x: valueX, y: 1124 - 50 - 18, width: 32, height: 18))
        captureEnabled.controlSize = .mini
        captureEnabled.target = self
        captureEnabled.action = #selector(changeCapture(_:))
        captureEnabled.setAccessibilityIdentifier("settings.capture.enabled")
        captureEnabled.setAccessibilityLabel(captureLocalize("Show Capture Bar"))
        form.addSubview(captureEnabled)
        let switchText = field(captureLocalize("Show Capture Bar"), top: 49, id: "settings.capture.enabled.title")
        switchText.frame.origin.x = valueX + 40
        field(captureLocalize("When enabled, Mado starts a small capture helper. Screen Recording permission belongs only to the helper; turning the switch off stops it."),
              top: 76, height: 42, id: "settings.capture.privacy-hint", muted: true)
        field(captureLocalize("Start at Login"), top: 125, labelColumn: true)
        disabledSwitch(captureLocalize("Start Capture Bar at Login"), top: 125, id: "settings.capture.login")
        field(captureLocalize("When off, the Capture Bar will not appear after restarting your Mac."),
              top: 151, height: 24, id: "settings.capture.login-hint", muted: true)
        field(captureLocalize("Screen Recording"), top: 190, labelColumn: true)
        capturePermissionStatus = field(captureLocalize("Unknown"), top: 190, id: "settings.capture.permission-status", muted: true)
        if #available(macOS 15, *) {
            field(captureLocalize("On macOS 15 and later, the system may ask again from time to time whether Mado can capture the screen. This is required by macOS; choose Allow to continue taking screenshots."),
                  top: 218, height: 42, id: "settings.capture.permission-note", muted: true)
        }
        heading(captureLocalize("After Capture"), top: 280, id: "settings.capture.heading-after", divider: true)
        field(captureLocalize("Capture Folder"), top: 315, id: "settings.capture.folder-label", labelColumn: true)
        let folder = field("~/Downloads", top: 315, id: "settings.capture.folder")
        folder.font = DesignMetrics.font("uiSmall", monospaced: true)
        disabledButton(captureLocalize("Change…"), top: 315, id: "settings.capture.folder-change", x: valueX + 102, width: 72)
        field(captureLocalize("File name mado-20261113153012.png; the second capture in the same second adds -2."),
              top: 341, height: 30, id: "settings.capture.filename-hint", muted: true)
        field(captureLocalize("Save to Folder"), top: 385, labelColumn: true)
        disabledSwitch(captureLocalize("Save captures to the Capture Folder"), top: 385, id: "settings.capture.after-save", on: true)
        field(captureLocalize("Copy to Clipboard"), top: 423, labelColumn: true)
        disabledSwitch(captureLocalize("Copy captures to the Clipboard"), top: 423, id: "settings.capture.after-copy", on: true)
        heading(captureLocalize("Global Shortcuts"), top: 475, id: "settings.capture.heading-shortcuts", divider: true)
        for (index, name) in [captureLocalize("Region Capture"), captureLocalize("Window Capture"), captureLocalize("Full Screen Capture"), captureLocalize("Capture and Recognize Text"), captureLocalize("Show / Hide Capture Bar")].enumerated() {
            let top = CGFloat(510 + index * 38)
            field(name, top: top, id: "settings.capture.shortcut-label-\(index)", labelColumn: true)
            disabledButton(captureLocalize("Not Set"), top: top, id: index == 0 ? "settings.capture.shortcut-region" : "settings.capture.shortcut-\(index)", width: 96)
        }
        field(captureLocalize("The system shortcuts ⌘⇧3 / ⌘⇧4 / ⌘⇧5 remain available."),
              top: 704, height: 30, id: "settings.capture.system-shortcuts-hint", muted: true)
        let ocr = NSView(frame: NSRect(x: 26, y: 1124 - 900, width: 528, height: 160))
        ocr.setAccessibilityIdentifier("settings.capture.ocr")
        form.addSubview(ocr)
        let ocrDivider = NSBox(frame: NSRect(x: 0, y: 159, width: 528, height: 1))
        ocrDivider.boxType = .separator
        ocr.addSubview(ocrDivider)
        let ocrTitle = label(captureLocalize("Text Recognition"), role: "uiSmall", muted: true)
        ocrTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        ocrTitle.frame = NSRect(x: 0, y: 130, width: 120, height: 20)
        ocr.addSubview(ocrTitle)
        let cloudLabel = label(captureLocalize("Cloud Recognition"), role: "uiSmall")
        cloudLabel.alignment = .right
        cloudLabel.frame = NSRect(x: 0, y: 96, width: 120, height: 24)
        ocr.addSubview(cloudLabel)
        let ocrInfo = label(captureLocalize("Cloud Recognition · No Key"), role: "uiSmall", muted: true)
        ocrInfo.frame = NSRect(x: 176, y: 96, width: 352, height: 24)
        ocr.addSubview(ocrInfo)
        let ocrCloud = NSSwitch(frame: NSRect(x: 136, y: 98, width: 32, height: 18))
        ocrCloud.controlSize = .mini
        ocrCloud.setAccessibilityLabel(captureLocalize("Cloud Recognition"))
        ocrCloud.isEnabled = false
        ocrCloud.setAccessibilityIdentifier("settings.capture.ocr-cloud")
        ocr.addSubview(ocrCloud)
        let serviceLabel = label(captureLocalize("Service"), role: "uiSmall")
        serviceLabel.alignment = .right
        serviceLabel.frame = NSRect(x: 0, y: 58, width: 120, height: 24)
        ocr.addSubview(serviceLabel)
        let service = NSPopUpButton(frame: NSRect(x: 136, y: 58, width: 140, height: 24), pullsDown: false)
        service.addItem(withTitle: captureLocalize("Baidu OCR"))
        service.isEnabled = false
        service.setAccessibilityIdentifier("settings.capture.ocr-service")
        ocr.addSubview(service)
        refreshCapture()
    }

    private func refreshCapture() {
        guard captureEnabled != nil else { return }
        captureRefreshID += 1
        let refreshID = captureRefreshID
        Task {
            let enabled = await capturePreferences.isCaptureBarEnabled()
            let permission = await capturePreferences.capturePermissionState()
            guard refreshID == captureRefreshID else { return }
            captureEnabled.state = enabled ? .on : .off
            switch permission {
            case .granted: capturePermissionStatus?.stringValue = captureLocalize("Granted")
            case .denied: capturePermissionStatus?.stringValue = captureLocalize("Denied")
            case .notAsked: capturePermissionStatus?.stringValue = captureLocalize("Not Asked")
            case nil: capturePermissionStatus?.stringValue = captureLocalize("Unknown")
            }
            for detail in captureDetails { detail.alphaValue = enabled && !(detail is NSButton) ? 1 : 0.45 }
        }
    }

    @objc private func changeCapture(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        sender.isEnabled = false
        Task {
            do { try await captureControl.setEnabled(enabled) }
            catch { sender.state = .off }
            sender.isEnabled = true
            refreshCapture()
        }
    }

    private func buildGeneral() {
        let pane = panes[.general]!
        rowLabel(String(localized: "Appearance"), y: 397, in: pane)
        let titles: [(DisplayAppearance, String)] = [
            (.system, String(localized: "Follow System")),
            (.light, String(localized: "Light")),
            (.dark, String(localized: "Dark"))
        ]
        var x: CGFloat = 162
        for (index, item) in titles.enumerated() {
            let button = NSButton(title: item.1, target: self, action: #selector(changeAppearance(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.setButtonType(.pushOnPushOff)
            button.font = DesignMetrics.font("uiSmall")
            button.setAccessibilityRole(.radioButton)
            let width = max(62, button.intrinsicContentSize.width + 14)
            button.frame = NSRect(x: x, y: 397, width: width, height: 24)
            button.setAccessibilityIdentifier("settings.appearance.\(item.0.rawValue)")
            pane.addSubview(button)
            appearanceButtons[item.0] = button
            x += width + 2
        }
        rowLabel(String(localized: "Image Tools"), y: 350, in: pane)
        toolsButton = NSButton(checkboxWithTitle: String(localized: "Always Show Image Tools"),
                               target: self, action: #selector(changeTools(_:)))
        toolsButton.font = DesignMetrics.font("ui")
        toolsButton.frame = NSRect(x: 162, y: 350, width: toolsButton.intrinsicContentSize.width, height: 24)
        toolsButton.setAccessibilityIdentifier("settings.always-show-tools")
        pane.addSubview(toolsButton)
        let hint = label(String(localized: "When off, tools hide after inactivity. Move the pointer to an edge or press Tab to show them."), role: "uiSmall", muted: true)
        hint.frame = NSRect(x: 162, y: 310, width: 390, height: 36)
        pane.addSubview(hint)
        rowLabel(String(localized: "Language"), y: 275, in: pane)
        let language = label(String(localized: "Follows the system language (Chinese / English). Set a language for Mado in System Settings → General → Language & Region."), role: "uiSmall", muted: true)
        language.frame = NSRect(x: 162, y: 232, width: 390, height: 67)
        language.setAccessibilityIdentifier("settings.language-note")
        pane.addSubview(language)
    }

    func entryPoint(for control: NSControl) -> EntryPoint? {
        entryPoints[ObjectIdentifier(control)]
    }

    private func configure(_ control: NSControl, entry: EntryPoint, id: String, title: String) {
        control.font = DesignMetrics.font("ui")
        control.isEnabled = entry.isEnabled
        control.setAccessibilityIdentifier(id)
        let marker = entry.accessibilityLabel(for: .preferred)
        control.setAccessibilityLabel(marker.isEmpty ? title : "\(title) · \(marker)")
        if let button = control as? NSButton {
            button.refusesFirstResponder = !entry.isFocusable
            button.keyEquivalent = entry.keyEquivalent ?? ""
        }
        entryPoints[ObjectIdentifier(control)] = entry
    }

    /// settings.html 显示 pane: the grid-display.html `.grid-tools-panel` preferences (one shared store, #114).
    private func buildDisplay() {
        let pane = panes[.display]!
        rowLabel(String(localized: "Thumbnail Size"), y: 397, in: pane)
        final class ThumbnailSizeSlider: NSSlider {
            override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
            override var canBecomeKeyView: Bool { acceptsFirstResponder }
            // Expose one live slider at this control, without duplicate elements from its hosted children.
            override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
            override func accessibilityChildren() -> [Any]? { [] }
            override func accessibilityRole() -> NSAccessibility.Role? { .slider }
            override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
            override func accessibilityMinValue() -> Any? { NSNumber(value: minValue) }
            override func accessibilityMaxValue() -> Any? { NSNumber(value: maxValue) }
            override func accessibilityPerformIncrement() -> Bool { changeValue(by: 10) }
            override func accessibilityPerformDecrement() -> Bool { changeValue(by: -10) }
            private func changeValue(by delta: Double) -> Bool {
                guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
                let next = min(maxValue, max(minValue, doubleValue + delta))
                guard next != doubleValue else { return false }
                doubleValue = next
                return sendAction(action, to: target)
            }
        }
        displaySize = ThumbnailSizeSlider(value: 220, minValue: 140, maxValue: 280,
            target: self, action: #selector(changeThumbnailSize(_:)))
        displaySize.numberOfTickMarks = 15
        displaySize.allowsTickMarkValuesOnly = true
        displaySize.frame = NSRect(x: 162, y: 397, width: 220, height: 24)
        configure(displaySize, entry: .settingsDisplayThumbnailSize, id: "settings.display.size", title: String(localized: "Thumbnail Size"))
        pane.addSubview(displaySize)
        rowLabel(String(localized: "Show File Names"), y: 352, in: pane)
        displayNames = NSButton(checkboxWithTitle: String(localized: "Show names below thumbnails"),
                                target: self, action: #selector(changeFileNames(_:)))
        displayNames.font = DesignMetrics.font("ui")
        displayNames.frame = NSRect(x: 162, y: 352, width: displayNames.intrinsicContentSize.width, height: 24)
        configure(displayNames, entry: .settingsDisplayFileNames, id: "settings.display.names", title: String(localized: "Show File Names"))
        pane.addSubview(displayNames)
        rowLabel(String(localized: "Thumbnails"), y: 307, in: pane)
        var fitX: CGFloat = 162
        // A toggle pair styled like the 通用 appearance buttons.
        for (index, item) in [(ThumbnailFit.fill, String(localized: "Fill and Crop")),
                              (.fit, String(localized: "Fit Entire Image"))].enumerated() {
            let button = NSButton(title: item.1, target: self, action: #selector(changeThumbnailFit(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.setButtonType(.pushOnPushOff)
            configure(button, entry: .settingsDisplayFitMode, id: "settings.display.fit.\(index)", title: item.1)
            button.font = DesignMetrics.font("uiSmall")
            button.setAccessibilityRole(.radioButton)
            let width = max(62, button.intrinsicContentSize.width + 14)
            button.frame = NSRect(x: fitX, y: 307, width: width, height: 24)
            pane.addSubview(button)
            fitButtons[item.0] = button
            fitX += width + 2
        }
        let note = label(String(localized: "These are the same preferences as the grid footer Display panel; changes will sync immediately."), role: "uiSmall", muted: true)
        note.frame = NSRect(x: 162, y: 260, width: 390, height: 40)
        pane.addSubview(note)
        // Keep the Display columns; the English title wraps within the shared label column.
        let opacityTitle = label(String(localized: "Tool Background Opacity"))
        opacityTitle.alignment = .right
        opacityTitle.maximumNumberOfLines = 2
        opacityTitle.frame = NSRect(x: 26, y: 201, width: 120, height: 44)
        opacityTitle.setAccessibilityIdentifier("settings.display.tool-opacity.label")
        pane.addSubview(opacityTitle)
        toolOpacity = ToolBackgroundOpacitySlider(value: 50, minValue: 30, maxValue: 100,
            target: self, action: #selector(changeToolBackgroundOpacity(_:)))
        toolOpacity.isContinuous = true
        toolOpacity.font = DesignMetrics.font("ui")
        toolOpacity.frame = NSRect(x: 162, y: 211, width: 220, height: 24)
        toolOpacity.setAccessibilityIdentifier("settings.display.tool-opacity")
        toolOpacity.setAccessibilityLabel(String(localized: "Tool Background Opacity"))
        pane.addSubview(toolOpacity)
        toolOpacityValue = label("50%")
        toolOpacityValue.font = DesignMetrics.font("ui", monospaced: true)
        toolOpacityValue.alignment = .right
        toolOpacityValue.frame = NSRect(x: 392, y: 211, width: 54, height: 24)
        toolOpacityValue.setAccessibilityIdentifier("settings.display.tool-opacity.value")
        pane.addSubview(toolOpacityValue)
    }

    private func buildCache() {
        let pane = panes[.cache]!
        rowLabel(String(localized: "Thumbnail Cache"), y: 397, in: pane)
        cacheSize = label(String(localized: "Unknown"), role: "uiSmall")
        cacheSize.font = DesignMetrics.font("uiSmall", monospaced: true)
        cacheSize.frame = NSRect(x: 162, y: 397, width: 350, height: 24)
        cacheSize.setAccessibilityIdentifier("settings.cache.size")
        pane.addSubview(cacheSize)
        cacheClear = NSButton(title: String(localized: "Clear Cache…"), target: self, action: #selector(requestClear(_:)))
        cacheClear.font = DesignMetrics.font("ui")
        cacheClear.frame = NSRect(x: 162, y: 353, width: cacheClear.intrinsicContentSize.width, height: 26)
        cacheClear.setAccessibilityIdentifier("settings.cache.clear")
        pane.addSubview(cacheClear)
        let hint = label(String(localized: "Only thumbnails created by Mado are deleted. Your images are untouched. Confirm before clearing; thumbnails are rebuilt while browsing."), role: "uiSmall", muted: true)
        hint.frame = NSRect(x: 162, y: 302, width: 390, height: 45)
        pane.addSubview(hint)
        cacheDiagnostic = label("", role: "uiSmall", muted: true)
        cacheDiagnostic.frame = NSRect(x: 162, y: 274, width: 390, height: 24)
        cacheDiagnostic.setAccessibilityIdentifier("settings.cache.diagnostic")
        pane.addSubview(cacheDiagnostic)
    }

    private static var versionDescription: String {
        versionDescription(info: Bundle.main.infoDictionary ?? [:])
    }

    private static func versionDescription(
        info: [String: Any],
        localized: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) }
    ) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? localized("Unknown")
        let build = info["CFBundleVersion"] as? String ?? localized("Unknown")
        return String(format: localized("%@ (build %@)"), version, build)
    }

    private func buildUpdates() {
        let pane = panes[.update]!
        rowLabel(String(localized: "Current Version"), y: 397, in: pane)
        updateVersion = label(Self.versionDescription, role: "uiSmall")
        updateVersion.frame = NSRect(x: 162, y: 397, width: 350, height: 24)
        updateVersion.setAccessibilityIdentifier("settings.update.version")
        pane.addSubview(updateVersion)
        rowLabel(String(localized: "Auto Check"), y: 352, in: pane)
        updateAutomatic = NSButton(checkboxWithTitle: String(localized: "Check for updates automatically"),
                                   target: self, action: #selector(changeAutomaticUpdates(_:)))
        updateAutomatic.font = DesignMetrics.font("ui")
        updateAutomatic.frame = NSRect(x: 162, y: 352, width: updateAutomatic.intrinsicContentSize.width, height: 24)
        configure(updateAutomatic, entry: .settingsUpdatesAutomaticCheck, id: "settings.update.automatic", title: updateAutomatic.title)
        pane.addSubview(updateAutomatic)
        let explanation = updates?.isAvailable == true
            ? String(localized: "Mado contacts GitHub only to check for updates and sends no system information.")
            : String(localized: "Updates are not available in this build.")
        let privacy = label(explanation, role: "uiSmall", muted: true)
        privacy.frame = NSRect(x: 162, y: 310, width: 390, height: 36)
        pane.addSubview(privacy)
        updateCheck = NSButton(title: String(localized: "Check Now"), target: self, action: #selector(checkForUpdates(_:)))
        updateCheck.font = DesignMetrics.font("ui")
        updateCheck.frame = NSRect(x: 162, y: 275, width: updateCheck.intrinsicContentSize.width, height: 26)
        configure(updateCheck, entry: .settingsUpdatesCheckNow, id: "settings.update.now", title: updateCheck.title)
        pane.addSubview(updateCheck)
        updateLastChecked = label(String(localized: "Last checked: Unknown"), role: "uiSmall", muted: true)
        updateLastChecked.frame = NSRect(x: 162, y: 247, width: 390, height: 24)
        updateLastChecked.setAccessibilityIdentifier("settings.update.last-checked")
        pane.addSubview(updateLastChecked)
        if updates?.isAvailable != true {
            // No updater (including builds without a feed): controls stay visible but inert.
            updateAutomatic.isEnabled = false
            updateCheck.isEnabled = false
        }
        refreshUpdates()
    }

    private func refreshUpdates() {
        guard let updates else { return }
        let unknown = String(localized: "Unknown")
        updateVersion.stringValue = String(format: String(localized: "%@ (build %@)"),
                                           updates.versionInfo.version ?? unknown, updates.versionInfo.build ?? unknown)
        updateAutomatic.state = updates.automaticallyChecksForUpdates ? .on : .off
        updateAutomatic.isEnabled = updates.isAvailable
        updateCheck.isEnabled = updates.isAvailable && updates.canCheckForUpdates
        updateLastChecked.stringValue = updates.lastUpdateCheckDate.map {
            String(format: String(localized: "Last checked: %@"), $0.formatted(date: .abbreviated, time: .shortened))
        } ?? String(localized: "Last checked: Unknown")
    }

    @objc private func changeAutomaticUpdates(_ sender: NSButton) {
        updates?.automaticallyChecksForUpdates = sender.state == .on
        refreshUpdates()
    }

    @objc private func checkForUpdates(_ sender: NSButton) {
        updates?.checkForUpdates()
        refreshUpdates()
    }

    private func buildAbout() {
        let pane = panes[.about]!
        let icon = NSImageView(frame: NSRect(x: 26, y: 362, width: 64, height: 64))
        icon.image = NSImage(named: NSImage.applicationIconName)
        pane.addSubview(icon)
        let name = label("Mado", role: "title", bold: true)
        name.frame = NSRect(x: 108, y: 406, width: 380, height: 20)
        pane.addSubview(name)
        let info = aboutInfoDictionary ?? Bundle.main.infoDictionary ?? [:]
        let description = Self.versionDescription(info: info, localized: aboutLocalizedString)
        let version = label(aboutLocalizedString("Version") + " " + description, role: "uiSmall", muted: true)
        version.textColor = DesignColor.textSecondary.nsColor
        version.frame = NSRect(x: 108, y: 383, width: 390, height: 20)
        pane.addSubview(version)
        let privacy = label(aboutLocalizedString("A macOS image viewer for files on your disk. Mado collects no data and uploads no images; the sandbox reads only folders you authorize."), role: "uiSmall", muted: true)
        privacy.textColor = DesignColor.textSecondary.nsColor
        privacy.frame = NSRect(x: 108, y: 319, width: 446, height: 54)
        pane.addSubview(privacy)
        let links: [(title: String, entry: EntryPoint)] = [
            (aboutLocalizedString("Report a Problem…"), .reportIssue),
            (aboutLocalizedString("Privacy Note"), .settingsAboutPrivacyNote),
            (aboutLocalizedString("Source Code"), .settingsAboutSourceCode),
        ]
        var linkX: CGFloat = 108
        for (index, link) in links.enumerated() {
            let isReport = link.entry == .reportIssue
            let button = NSButton(title: link.title, target: self,
                                  action: isReport ? #selector(reportIssue(_:)) : #selector(openAboutLink(_:)))
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: link.title, attributes: [
                .font: DesignMetrics.font("ui"),
                .foregroundColor: DesignColor.selectionText.nsColor,
            ])
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: linkX, y: 283, width: width, height: 26)
            configure(button, entry: link.entry, id: "settings.about.link.\(index)", title: link.title)
            pane.addSubview(button)
            linkX += width + 14
        }
        let licences = label(aboutLocalizedString("Mado is released under the MIT License.\nThird party: Sparkle (MIT) · Welcome sample images from Unsplash (Unsplash License)."), role: "uiSmall", muted: true)
        licences.textColor = DesignColor.textSecondary.nsColor
        licences.frame = NSRect(x: 108, y: 219, width: 446, height: 52)
        pane.addSubview(licences)
    }

    private func renderCache() {
        if model.isMeasuring { cacheSize.stringValue = String(localized: "Measuring…") }
        else if let bytes = model.sizeBytes { cacheSize.stringValue = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        else { cacheSize.stringValue = String(localized: "Unknown") }
        cacheDiagnostic.stringValue = model.diagnostic.map { String(localized: String.LocalizationValue($0)) } ?? ""
        cacheClear.isEnabled = !model.isMeasuring && !model.isClearing
    }

    private func showCacheBusy() {
        cacheSize.stringValue = String(localized: "Measuring…")
        cacheClear.isEnabled = false
    }

    private func refreshCache() {
        showCacheBusy()
        Task {
            showCacheBusy()
            await model.refresh()
            renderCache()
        }
    }

    private static func presentClearConfirmation(window: NSWindow, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Thumbnail Cache?")
        alert.informativeText = String(localized: "This deletes Mado thumbnails only. Your images are untouched.")
        alert.addButton(withTitle: String(localized: "Clear Cache"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
    }

    @objc private func requestClear(_ sender: NSButton) {
        confirmClear(window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.showCacheBusy()
            Task {
                self.showCacheBusy()
                await self.model.clear()
                self.renderCache()
            }
        }
    }

    @objc private func selectSidebar(_ sender: NSButton) {
        select(SettingsSection.allCases[sender.tag])
    }

    @objc private func changeAppearance(_ sender: NSButton) {
        let appearance: DisplayAppearance = [.system, .light, .dark][sender.tag]
        preferencesStore.value.appearance = appearance
        preferencesDidChange(preferencesStore.value)
    }

    @objc private func reportIssue(_ sender: NSButton) {
        openURL(EntryPoint.reportIssueURL)
    }

    @objc private func openAboutLink(_ sender: NSButton) {
        switch entryPoint(for: sender) {
        case .settingsAboutPrivacyNote: openURL(EntryPoint.settingsAboutPrivacyNoteURL)
        case .settingsAboutSourceCode: openURL(EntryPoint.settingsAboutSourceCodeURL)
        default: break
        }
    }

    /// Changes one field of the store's current value, then reflects it (a re-clicked fit button stays on).
    private func writeDisplay(_ change: (inout DisplayPreferences) -> Void) {
        var value = preferencesStore.value
        change(&value)
        preferencesStore.value = value
        preferencesDidChange(preferencesStore.value)
    }

    @objc private func changeThumbnailSize(_ sender: NSSlider) {
        let size = DisplayPreferences.normalizedThumbnailSize(sender.doubleValue)
        writeDisplay { $0.thumbnailSize = size }
    }

    @objc private func changeToolBackgroundOpacity(_ sender: NSSlider) {
        let opacity = DisplayPreferences.normalizedToolBackgroundOpacity(sender.doubleValue)
        writeDisplay { $0.toolBackgroundOpacity = opacity }
    }

    @objc private func changeFileNames(_ sender: NSButton) {
        let names = sender.state == .on
        writeDisplay { $0.showFileNames = names }
    }

    @objc private func changeThumbnailFit(_ sender: NSButton) {
        let fit: ThumbnailFit = sender.tag == 1 ? .fit : .fill
        writeDisplay { $0.thumbnailFit = fit }
    }

    @objc private func changeTools(_ sender: NSButton) {
        preferencesStore.value.alwaysShowTools = sender.state == .on
    }
}

private final class ToolBackgroundOpacitySlider: NSSlider {
    static func percentage(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
    override func accessibilityValueDescription() -> String? { Self.percentage(doubleValue) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: minValue) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: maxValue) }
    override func accessibilityPerformIncrement() -> Bool { changeValue(by: 1) }
    override func accessibilityPerformDecrement() -> Bool { changeValue(by: -1) }
    override func keyDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return }
        super.keyDown(with: event)
    }
    private func changeValue(by delta: Double) -> Bool {
        guard acceptsFirstResponder else { return false }
        let next = min(maxValue, max(minValue, doubleValue + delta))
        guard next != doubleValue else { return false }
        doubleValue = next
        return sendAction(action, to: target)
    }
}

private final class SettingsPanelNativeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

private final class SettingsSidebarButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            DesignColor.selectionFill.nsColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SettingsSurfaceView: NSView {
    enum Surface { case panel, sidebar }
    let surface: Surface
    init(frame: NSRect, surface: Surface) { self.surface = surface; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = surface == .sidebar
            ? DesignColor.sidebarBackground.nsColor : DesignColor.popoverBackground.nsColor
        color.setFill()
        dirtyRect.fill()
        if surface == .sidebar {
            DesignColor.divider.nsColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
