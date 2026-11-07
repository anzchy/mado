import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor func issue220Panel(_ port: FakeUpdatePort?) -> SettingsPanelWindow {
    let preferences = InMemoryDisplayPreferencesStore()
    let defaults = UserDefaults(suiteName: "issue220-\(UUID().uuidString)")!
    let cache = ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let panel = SettingsPanelWindow(cache: cache, appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
                                    preferencesStore: preferences, defaults: defaults, updates: port)
    panel.select(.update)
    return panel
}

@MainActor func issue220View(_ id: String, in panel: SettingsPanelWindow) -> NSView? {
    func find(_ view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }
    return panel.window.contentView.flatMap(find)
}

@MainActor func issue220Text(_ id: String, in panel: SettingsPanelWindow) throws -> String {
    try #require(issue220View(id, in: panel) as? NSTextField, "missing \(id)").stringValue
}

func issue220LastChecked(_ date: Date?) -> String {
    guard let date else { return String(localized: "Last checked: Unknown") }
    return String(format: String(localized: "Last checked: %@"), date.formatted(date: .abbreviated, time: .shortened))
}

private func versionText(_ version: String?, _ build: String?) -> String {
    let unknown = String(localized: "Unknown")
    return String(format: String(localized: "%@ (build %@)"), version ?? unknown, build ?? unknown)
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor @Test func issue220UpdateControlsAreEnabledWithoutComingSoon() throws {
    let panel = issue220Panel(FakeUpdatePort())
    defer { panel.window.close() }
    let pane = try #require(issue220View("settings.pane.update", in: panel))
    #expect(!pane.subviews.contains { ($0 as? NSTextField)?.stringValue == String(localized: "Coming Soon") })
    let expected: [(String, EntryPoint)] = [
        ("settings.update.automatic", .settingsUpdatesAutomaticCheck), ("settings.update.now", .settingsUpdatesCheckNow),
    ]
    for (id, entry) in expected {
        let button = try #require(issue220View(id, in: panel) as? NSButton, "\(id)")
        #expect(button.isEnabled, "\(id)")
        #expect(!button.refusesFirstResponder, "\(id)")
        #expect(button.accessibilityLabel() == button.title, "\(id)")
        #expect(panel.entryPoint(for: button) == entry, "\(id)")
    }
}

@MainActor @Test(arguments: [("2.3.0", "57"), (nil, "57"), ("2.3.0", nil), (nil, nil)] as [(String?, String?)])
func issue220VersionLabelShowsPortVersionAndBuild(version: String?, build: String?) throws {
    let panel = issue220Panel(FakeUpdatePort(version: version, build: build))
    defer { panel.window.close() }
    #expect(try issue220Text("settings.update.version", in: panel) == versionText(version, build))
}

@MainActor @Test(arguments: [(UInt64(0x2201), false), (UInt64(0x2202), true)])
func issue220AutomaticToggleRoundTripsThroughPort(seed: UInt64, initial: Bool) throws {
    let port = FakeUpdatePort(automatic: initial)
    let panel = issue220Panel(port)
    defer { panel.window.close() }
    let checkbox = try #require(issue220View("settings.update.automatic", in: panel) as? NSButton)
    var generator = SplitMix64(state: seed)
    func agrees(_ step: Int, _ op: String) {
        #expect(checkbox.state == (port.automaticallyChecksForUpdates ? .on : .off), "seed \(seed) step \(step) \(op)")
    }
    agrees(-1, "initial")
    for step in 0..<40 {
        switch Int.random(in: 0..<6, using: &generator) {
        case 0, 1:
            let before = port.automaticallyChecksForUpdates
            checkbox.performClick(nil)
            #expect(port.automaticallyChecksForUpdates == !before, "seed \(seed) step \(step) click")
            agrees(step, "click")
        case 2:
            port.simulateExternal(automatic: Bool.random(using: &generator))
            agrees(step, "external")
        case 3:
            port.simulateExternal(automatic: port.automaticallyChecksForUpdates)
            agrees(step, "external same")
        case 4:
            panel.select(.general)
            panel.select(.update)
            agrees(step, "reselect")
        default:
            port.automaticallyChecksForUpdates.toggle()
            panel.select(.general)
            panel.select(.update)
            agrees(step, "silent external + reselect")
            let before = port.automaticallyChecksForUpdates
            checkbox.performClick(nil)
            #expect(port.automaticallyChecksForUpdates == !before, "seed \(seed) step \(step) click after silent")
            agrees(step, "click after silent")
        }
    }
    #expect(port.checkCount == 0)
}

@MainActor @Test func issue220CheckNowChecksOncePerClickAndShowsResultDate() throws {
    let date = try Date("2026-03-04T05:06:00Z", strategy: .iso8601)
    let port = FakeUpdatePort(automatic: true, nextCheckDate: date)
    let panel = issue220Panel(port)
    defer { panel.window.close() }
    let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
    #expect(port.checkCount == 0)
    #expect(try issue220Text("settings.update.last-checked", in: panel) == issue220LastChecked(nil))
    check.performClick(nil)
    #expect(port.checkCount == 1)
    #expect(try issue220Text("settings.update.last-checked", in: panel) == issue220LastChecked(date))
    check.performClick(nil)
    check.performClick(nil)
    #expect(port.checkCount == 3)
    #expect(port.automaticallyChecksForUpdates)
}

@MainActor @Test func issue220LastCheckedRendersDateOrUnknownAndRefreshesOnShow() throws {
    let first = try Date("2026-01-02T03:04:00Z", strategy: .iso8601)
    let second = first.addingTimeInterval(61)
    let port = FakeUpdatePort()
    let panel = issue220Panel(port)
    defer { panel.window.close() }
    func label() throws -> String { try issue220Text("settings.update.last-checked", in: panel) }
    #expect(try label() == String(localized: "Last checked: Unknown"))
    port.simulateExternal(date: .some(first))
    let firstLabel = try label()
    #expect(firstLabel == issue220LastChecked(first))
    #expect(issue220LastChecked(first) != issue220LastChecked(second))
    port.lastUpdateCheckDate = second
    #expect(try label() == firstLabel)
    panel.select(.general)
    panel.select(.update)
    #expect(try label() == issue220LastChecked(second))
    port.simulateExternal(date: .some(first))
    #expect(try label() == firstLabel)
    port.simulateExternal(date: .some(nil))
    #expect(try label() == String(localized: "Last checked: Unknown"))
}

@MainActor @Test func issue220NilPortDisablesUpdateControlsWithoutComingSoon() throws {
    let panel = issue220Panel(nil)
    defer { panel.window.close() }
    let pane = try #require(issue220View("settings.pane.update", in: panel))
    #expect(!pane.subviews.contains { ($0 as? NSTextField)?.stringValue == String(localized: "Coming Soon") })
    let expected: [(String, EntryPoint)] = [
        ("settings.update.automatic", .settingsUpdatesAutomaticCheck), ("settings.update.now", .settingsUpdatesCheckNow),
    ]
    for (id, entry) in expected {
        let button = try #require(issue220View(id, in: panel) as? NSButton, "\(id)")
        #expect(!button.isEnabled, "\(id)")
        #expect(button.accessibilityLabel() == button.title, "\(id)")
        #expect(panel.entryPoint(for: button) == entry, "\(id)")
        button.performClick(nil)
    }
    let info = Bundle.main.infoDictionary ?? [:]
    #expect(try issue220Text("settings.update.version", in: panel) == versionText(
        info["CFBundleShortVersionString"] as? String, info["CFBundleVersion"] as? String))
    #expect(try issue220Text("settings.update.last-checked", in: panel) == String(localized: "Last checked: Unknown"))
}
