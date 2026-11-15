import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #685 Settings › 截图 (design page 35, design/prototypes/picsee-browser/states/settings.html ?section=capture):
// global shortcut fields that record, refuse and restore (AC-1, AC-2), the Capture Folder row (AC-5), start at login
// with the approval state (AC-4), the exact macOS 15 line (AC-6), and greying while the bar is off (grilling 5.2).

private actor Bar: CaptureBarPreferencePort {
    var enabled: Bool
    init(_ enabled: Bool) { self.enabled = enabled }
    func isCaptureBarEnabled() -> Bool { enabled }
    func setCaptureBarEnabled(_ enabled: Bool) { self.enabled = enabled }
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

private actor Shortcuts: CaptureShortcutPreferencePort {
    var stored: CaptureShortcutBindings
    var refused: [CaptureShortcutAction: CaptureKeyCombo]
    init(_ stored: CaptureShortcutBindings = .defaults, refused: [CaptureShortcutAction: CaptureKeyCombo] = [:]) {
        self.stored = stored
        self.refused = refused
    }
    func bindings() -> CaptureShortcutBindings { stored }
    func setBindings(_ bindings: CaptureShortcutBindings) { stored = bindings }
    func failures() -> [CaptureShortcutAction: CaptureKeyCombo] { refused }
    func setFailures(_ failures: [CaptureShortcutAction: CaptureKeyCombo]) { refused = failures }
}

private actor Folder: CaptureFolderPreferencePort {
    var record: CaptureFolderRecord
    init(_ record: CaptureFolderRecord = .downloads) { self.record = record }
    func folderRecord() -> CaptureFolderRecord { record }
    func setFolderRecord(_ record: CaptureFolderRecord) { self.record = record }
}

private actor LoginItem: CaptureLoginItemPort {
    var current: CaptureLoginItemStatus
    var statusAfterRegister: CaptureLoginItemStatus = .enabled
    var registers = 0
    var unregisters = 0
    var opened = 0
    init(_ status: CaptureLoginItemStatus) { current = status }
    func status() -> CaptureLoginItemStatus { current }
    func register() { registers += 1; current = statusAfterRegister }
    func unregister() { unregisters += 1; current = .notRegistered }
    func openLoginItemsSettings() { opened += 1 }
    func set(_ status: CaptureLoginItemStatus) { current = status }
    func approveLater() { statusAfterRegister = .requiresApproval }
}

@MainActor private final class Signals {
    var names: [String] = []
}

@MainActor private struct Fixture {
    let panel: SettingsPanelWindow
    let shortcuts: Shortcuts
    let folder: Folder
    let login: LoginItem
    let signals: Signals

    init(bar: Bool = true, shortcuts: Shortcuts = Shortcuts(), folder: Folder = Folder(),
         login: LoginItem = LoginItem(.notRegistered), localize: @escaping (String) -> String = { $0 }) {
        let preferences = InMemoryDisplayPreferencesStore()
        let signals = Signals()
        self.shortcuts = shortcuts
        self.folder = folder
        self.login = login
        self.signals = signals
        panel = SettingsPanelWindow(
            cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
            preferencesStore: preferences,
            defaults: UserDefaults(suiteName: "issue685-\(UUID().uuidString)")!,
            capturePreferences: Bar(bar), captureLocalize: localize,
            captureShortcuts: shortcuts, captureFolder: folder, captureLoginItem: login,
            captureSignal: { signals.names.append($0) })
        panel.select(.capture)
    }

    func view(_ id: String) -> NSView? {
        func walk(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return panel.window.contentView.flatMap(walk)
    }

    func field(_ index: Int) throws -> CaptureShortcutField {
        try #require(view(index == 0 ? "settings.capture.shortcut-region" : "settings.capture.shortcut-\(index)")
            as? CaptureShortcutField)
    }

    func message(_ index: Int) throws -> NSTextField {
        try #require(view("settings.capture.shortcut-message-\(index)") as? NSTextField)
    }
}

/// Polls until `condition` holds or about two seconds pass.
@MainActor private func eventually(_ condition: () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

private let ctrlShiftCmd: NSEvent.ModifierFlags = [.control, .shift, .command]

@MainActor @Test(.timeLimit(.minutes(3))) func issue685ShortcutFieldsShowBindingsAndMatchTheDesign() async throws {
    var bindings = CaptureShortcutBindings.defaults
    bindings.clear(.toggleBar)
    let fixture = Fixture(shortcuts: Shortcuts(bindings))
    defer { fixture.panel.window.close() }
    let region = try fixture.field(0)
    await eventually { region.isEnabled }
    #expect(region.isEnabled)
    #expect(try fixture.field(0).title == "⌃⇧⌘1")
    #expect(try fixture.field(1).title == "⌃⇧⌘2")
    #expect(try fixture.field(2).title == "⌃⇧⌘3")
    #expect(try fixture.field(3).title == "⌃⇧⌘4")
    // settings.html:99-100 .shortcut-field: min-width 96px, height 24px, font-family var(--font-mono), font-size ui-sm.
    #expect(region.frame.width >= 96)
    #expect(region.frame.height == 24)
    #expect(region.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    #expect(region.font?.pointSize == DesignMetrics.font("uiSmall").pointSize)
    // settings.html:101,165 .shortcut-field.unset: 未设置, color muted, font-family sans.
    let toggle = try fixture.field(4)
    #expect(toggle.title == "Not Set")
    #expect(toggle.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
    #expect(toggle.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == DesignColor.textSecondary.nsColor)
    #expect(region.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == DesignColor.textPrimary.nsColor)
    // settings.html:161 aria-label 区域截图快捷键, title 点按后按下新的快捷键.
    #expect(region.accessibilityLabel() == "Region Capture Shortcut")
    #expect(region.toolTip == "Click, then press the new shortcut")
    // settings.html:166 恢复默认 link after the system-shortcut hint.
    let restore = try #require(fixture.view("settings.capture.shortcut-restore") as? NSButton)
    #expect(restore.title == "Restore Defaults")
    #expect(!restore.isBordered)
    #expect(restore.isEnabled)
    #expect(abs(try fixture.field(1).frame.midY - region.frame.midY) == 38)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685RecordingAShortcutRebindsPersistsAndTellsTheHelper() async throws {
    let fixture = Fixture()
    defer { fixture.panel.window.close() }
    let region = try fixture.field(0)
    await eventually { region.isEnabled }
    region.performClick(nil)
    #expect(region.isRecording)
    #expect(region.title == "Type Shortcut…")
    #expect(fixture.signals.names == [CaptureBarIdentity.recordingBeganNotification])
    region.keyDown(with: key(3, "f", [.control, .option]))
    await eventually { await fixture.shortcuts.stored[.region]?.keyCode == 3 }
    #expect(await fixture.shortcuts.stored[.region] == CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option]))
    #expect(!region.isRecording)
    await eventually { fixture.signals.names.count == 3 }
    #expect(fixture.signals.names == [CaptureBarIdentity.recordingBeganNotification,
                                      CaptureBarIdentity.shortcutsChangedNotification,
                                      CaptureBarIdentity.recordingEndedNotification])
    await eventually { region.title == "⌃⌥F" }
    #expect(region.title == "⌃⌥F")
    // ⌘ combos arrive as key equivalents while the field records.
    region.performClick(nil)
    #expect(region.performKeyEquivalent(with: key(5, "g", [.command, .option])))
    await eventually { await fixture.shortcuts.stored[.region]?.keyCode == 5 }
    #expect(await fixture.shortcuts.stored[.region] == CaptureKeyCombo(keyCode: 5, key: "G", modifiers: [.command, .option]))
    #expect(!region.performKeyEquivalent(with: key(5, "g", [.command, .option])))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685RecordingRefusesSystemAndTakenCombosWithAMessage() async throws {
    let fixture = Fixture()
    defer { fixture.panel.window.close() }
    let region = try fixture.field(0)
    await eventually { region.isEnabled }
    region.performClick(nil)
    region.keyDown(with: key(21, "4", [.command, .shift]))
    await eventually { (try? fixture.message(0).stringValue.isEmpty) == false }
    #expect(try fixture.message(0).stringValue == "⇧⌘4 is a macOS screenshot shortcut and stays with the system.")
    #expect(try fixture.message(0).textColor == DesignColor.errorText.nsColor)
    #expect(await fixture.shortcuts.stored == .defaults)
    region.performClick(nil)
    region.keyDown(with: key(19, "2", ctrlShiftCmd))
    await eventually { (try? fixture.message(0).stringValue) == "⌃⇧⌘2 is already used by Window Capture." }
    #expect(try fixture.message(0).stringValue == "⌃⇧⌘2 is already used by Window Capture.")
    region.performClick(nil)
    region.keyDown(with: key(0, "A", [.shift]))
    await eventually { (try? fixture.message(0).stringValue) == "A shortcut needs ⌘, ⌃ or ⌥." }
    #expect(try fixture.message(0).stringValue == "A shortcut needs ⌘, ⌃ or ⌥.")
    #expect(await fixture.shortcuts.stored == .defaults)
    #expect(!fixture.signals.names.contains(CaptureBarIdentity.shortcutsChangedNotification))
    #expect(fixture.signals.names.filter { $0 == CaptureBarIdentity.recordingEndedNotification }.count == 3)
    // Esc cancels: nothing changes and the message stays.
    region.performClick(nil)
    region.keyDown(with: key(53, "\u{1b}", []))
    #expect(!region.isRecording)
    await eventually { region.title == "⌃⇧⌘1" }
    #expect(region.title == "⌃⇧⌘1")
    #expect(await fixture.shortcuts.stored == .defaults)
    // A good combo clears the message.
    region.performClick(nil)
    region.keyDown(with: key(3, "f", [.control, .option]))
    await eventually { (try? fixture.message(0).stringValue) == "" }
    #expect(try fixture.message(0).stringValue == "")
    // Delete clears the binding.
    let window = try fixture.field(1)
    window.performClick(nil)
    window.keyDown(with: key(51, "\u{7f}", []))
    await eventually { await fixture.shortcuts.stored[.window] == nil }
    #expect(await fixture.shortcuts.stored[.window] == nil)
    await eventually { window.title == "Not Set" }
    #expect(window.title == "Not Set")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685ComboTheHelperCouldNotRegisterIsNamed() async throws {
    let taken = CaptureShortcutBindings.defaults[.fullScreen]!
    let shortcuts = Shortcuts(refused: [.fullScreen: taken])
    let fixture = Fixture(shortcuts: shortcuts)
    defer { fixture.panel.window.close() }
    await eventually { (try? fixture.message(2).stringValue.isEmpty) == false }
    #expect(try fixture.message(2).stringValue == "⌃⇧⌘3 is used by another app. Choose another shortcut.")
    #expect(try fixture.message(0).stringValue == "")
    // The helper's shortcutStatus notification refreshes the tab.
    await shortcuts.setFailures([:])
    NotificationCenter.default.post(name: SettingsPanelWindow.captureSignalNotification, object: nil,
                                    userInfo: ["name": CaptureBarIdentity.shortcutStatusNotification])
    await eventually { (try? fixture.message(2).stringValue) == "" }
    #expect(try fixture.message(2).stringValue == "")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685RestoreDefaultsPutsEveryShortcutBack() async throws {
    var bindings = CaptureShortcutBindings.defaults
    bindings.clear(.region)
    try bindings.bind(CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option]), to: .window)
    let fixture = Fixture(shortcuts: Shortcuts(bindings))
    defer { fixture.panel.window.close() }
    let restore = try #require(fixture.view("settings.capture.shortcut-restore") as? NSButton)
    await eventually { restore.isEnabled }
    restore.performClick(nil)
    await eventually { await fixture.shortcuts.stored == .defaults }
    #expect(await fixture.shortcuts.stored == .defaults)
    #expect(fixture.signals.names == [CaptureBarIdentity.shortcutsChangedNotification])
    await eventually { (try? fixture.field(0).title) == "⌃⇧⌘1" }
    #expect(try fixture.field(0).title == "⌃⇧⌘1")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685FolderRowShowsTheChosenFolderAndAsksTheHelperToChange() async throws {
    let folder = Folder(CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: false))
    let fixture = Fixture(folder: folder)
    defer { fixture.panel.window.close() }
    let path = try #require(fixture.view("settings.capture.folder") as? NSTextField)
    let change = try #require(fixture.view("settings.capture.folder-change") as? NSButton)
    let hint = try #require(fixture.view("settings.capture.filename-hint") as? NSTextField)
    await eventually { path.stringValue == "~/Pictures/Shots" }
    #expect(path.stringValue == "~/Pictures/Shots")
    // settings.html:154 .mono path, then the 更改… button.
    #expect(path.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    #expect((path.stringValue as NSString).size(withAttributes: [.font: path.font!]).width <= path.frame.width)
    #expect(change.frame.minX >= path.frame.maxX)
    #expect(change.title == "Change…")
    #expect(change.isEnabled)
    #expect(hint.stringValue == "File name mado-20261113153012.png; the second capture in the same second adds -2.")
    change.performClick(nil)
    #expect(fixture.signals.names == [CaptureBarIdentity.chooseFolderNotification])
    // A bookmark the helper could not open: captures go to ~/Downloads and the note names the folder.
    await folder.setFolderRecord(CaptureFolderRecord(bookmark: Data([1]), display: "~/Pictures/Shots", fellBack: true))
    NotificationCenter.default.post(name: SettingsPanelWindow.captureSignalNotification, object: nil,
                                    userInfo: ["name": CaptureBarIdentity.folderChangedNotification])
    await eventually { path.stringValue == "~/Downloads" }
    #expect(path.stringValue == "~/Downloads")
    #expect(hint.stringValue == "The chosen folder ~/Pictures/Shots can't be opened, so captures go to ~/Downloads. Choose it again.")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685LoginSwitchFollowsTheSystemStatusAndApproval() async throws {
    let login = LoginItem(.notRegistered)
    let fixture = Fixture(login: login)
    defer { fixture.panel.window.close() }
    let toggle = try #require(fixture.view("settings.capture.login") as? NSSwitch)
    let approval = try #require(fixture.view("settings.capture.login-open-settings") as? NSButton)
    let hint = try #require(fixture.view("settings.capture.login-hint") as? NSTextField)
    await eventually { toggle.isEnabled }
    #expect(toggle.isEnabled && toggle.state == .off)
    #expect(approval.isHidden)
    await login.approveLater()
    toggle.performClick(nil)
    await eventually { await login.registers == 1 }
    #expect(await login.registers == 1)
    await eventually { !approval.isHidden }
    #expect(toggle.state == .on)
    #expect(!approval.isHidden && approval.isEnabled)
    #expect(approval.title == "Open Login Items Settings")
    #expect(hint.stringValue == "Mado Capture needs your approval in System Settings › General › Login Items.")
    approval.performClick(nil)
    await eventually { await login.opened == 1 }
    #expect(await login.opened == 1)
    // The status is read again when the window comes back (after System Settings).
    await login.set(.enabled)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.panel.window)
    await eventually { approval.isHidden }
    #expect(approval.isHidden)
    #expect(hint.stringValue == "When off, the Capture Bar will not appear after restarting your Mac.")
    toggle.performClick(nil)
    await eventually { await login.unregisters == 1 }
    #expect(await login.unregisters == 1)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685CaptureBarOffGreysTheNewRows() async throws {
    let fixture = Fixture(bar: false, login: LoginItem(.requiresApproval))
    defer { fixture.panel.window.close() }
    let toggle = try #require(fixture.view("settings.capture.login") as? NSSwitch)
    await eventually { toggle.state == .on }
    let ids = ["settings.capture.login", "settings.capture.folder-change", "settings.capture.shortcut-region",
               "settings.capture.shortcut-1", "settings.capture.shortcut-2", "settings.capture.shortcut-3",
               "settings.capture.shortcut-4", "settings.capture.shortcut-restore"]
    for id in ids {
        let control = try #require(fixture.view(id) as? NSControl)
        // settings.html:94 .is-off opacity .45.
        #expect(!control.isEnabled, "\(id)")
        #expect(control.alphaValue == 0.45, "\(id)")
        #expect(CaptureDeferredSettingsControls.tickets[id] == nil)
        #expect(CaptureDeferredSettingsControls.barDependent.contains(id))
    }
    #expect(try #require(fixture.view("settings.capture.login-open-settings")).isHidden)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685MacOS15LineIsTheExactText() throws {
    let en = "On macOS 15 and later, the system asks again from time to time whether Mado may record the screen. This is a system requirement; choose Allow to keep capturing."
    let zh = "在 macOS 15 及以后，系统会不定期再次询问是否允许 Mado 截取屏幕。这是系统要求，选择允许即可继续截图。"
    #expect(try captureCatalog("en")[en] == en)
    #expect(try captureCatalog("zh-Hans")[en] == zh)
    let fixture = Fixture()
    defer { fixture.panel.window.close() }
    let note = try #require(fixture.view("settings.capture.permission-note") as? NSTextField)
    #expect(note.stringValue == en)
    let zhFixture = Fixture(localize: { (try? captureCatalog("zh-Hans"))?[$0] ?? $0 })
    defer { zhFixture.panel.window.close() }
    let zhNote = try #require(zhFixture.view("settings.capture.permission-note") as? NSTextField)
    #expect(zhNote.stringValue == zh)
    // settings.html:148 a hint line, not a dialog.
    #expect(NSApp.modalWindow == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685NewStringsAreTranslated() throws {
    let zh = try captureCatalog("zh-Hans")
    let expected = [
        "Type Shortcut…": "请按快捷键…",
        "%@ Shortcut": "%@快捷键",
        "Click, then press the new shortcut": "点按后按下新的快捷键",
        "Restore Defaults": "恢复默认",
        "A shortcut needs ⌘, ⌃ or ⌥.": "快捷键需要包含 ⌘、⌃ 或 ⌥。",
        "A shortcut needs a key besides the modifiers.": "快捷键需要一个修饰键以外的按键。",
        "%@ is a macOS screenshot shortcut and stays with the system.": "%@ 是 macOS 的截图快捷键，留给系统使用。",
        "%1$@ is already used by %2$@.": "%1$@ 已用于「%2$@」。",
        "%@ is used by another app. Choose another shortcut.": "%@ 已被其他 App 占用，请换一个快捷键。",
        "The chosen folder %@ can't be opened, so captures go to ~/Downloads. Choose it again.":
            "无法打开所选文件夹 %@，截图暂存到 ~/Downloads。请重新选择。",
        "Mado Capture needs your approval in System Settings › General › Login Items.":
            "需要在「系统设置 › 通用 › 登录项」中允许 Mado 截图。",
        "Open Login Items Settings": "打开登录项设置",
    ]
    for (key, value) in expected { #expect(zh[key] == value, "\(key)") }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685ShortcutFieldNamesKeysWithoutTheirModifiers() {
    #expect(CaptureShortcutField.combo(from: key(80, "\u{F716}", [.control, .option, .command]))
            == CaptureKeyCombo(keyCode: 80, key: "F19", modifiers: [.control, .option, .command]))
    #expect(CaptureShortcutField.combo(from: key(123, "\u{F702}", [.control, .function]))
            == CaptureKeyCombo(keyCode: 123, key: "←", modifiers: [.control]))
    #expect(CaptureShortcutField.combo(from: key(49, " ", [.option])).key == "Space")
    #expect(CaptureShortcutField.combo(from: key(18, "!", [.control, .shift])).key == "1")
    #expect(CaptureShortcutField.combo(from: key(3, "ƒ", [.option])).key == "F")
}
