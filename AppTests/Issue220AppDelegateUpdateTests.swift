import AppKit
import Testing
import MadoApplication

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

@MainActor private func text(_ id: String, in panel: SettingsPanelWindow) throws -> String {
    try #require(issue220View(id, in: panel) as? NSTextField, "missing \(id)").stringValue
}

@MainActor @Test func issue220AppDelegatePassesUpdatePortToSettings() throws {
    let date = try Date("2026-05-06T07:08:00Z", strategy: .iso8601)
    let port = FakeUpdatePort(version: "9.9.9-test", build: "4242", automatic: true, nextCheckDate: date)
    let suite = UserDefaults(suiteName: "issue220-delegate-\(UUID().uuidString)")!
    let delegate = AppDelegate()
    delegate.updates = port
    let panel = delegate.makeSettingsWindow(defaults: suite)
    defer { panel.window.close() }
    panel.select(.update)
    #expect(try text("settings.update.version", in: panel) == String(format: String(localized: "%@ (build %@)"), "9.9.9-test", "4242"))
    let automatic = try #require(issue220View("settings.update.automatic", in: panel) as? NSButton)
    #expect(automatic.isEnabled)
    #expect(automatic.state == .on)
    let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
    check.performClick(nil)
    #expect(port.checkCount == 1)
    #expect(try text("settings.update.last-checked", in: panel) == issue220LastChecked(date))
    #expect(suite.string(forKey: "settings.selectedSection.v1") == "update")
}

@MainActor @Test func issue220AppDelegateWithoutPortShowsInertUpdateControls() throws {
    let suite = UserDefaults(suiteName: "issue220-delegate-nil-\(UUID().uuidString)")!
    let delegate = AppDelegate()
    let panel = delegate.makeSettingsWindow(defaults: suite)
    defer { panel.window.close() }
    panel.select(.update)
    for id in ["settings.update.automatic", "settings.update.now"] {
        let button = try #require(issue220View(id, in: panel) as? NSButton, "\(id)")
        #expect(!button.isEnabled, "\(id)")
        #expect(button.accessibilityLabel() == button.title, "\(id)")
    }
    let pane = try #require(issue220View("settings.pane.update", in: panel))
    #expect(!pane.subviews.contains { ($0 as? NSTextField)?.stringValue == String(localized: "Coming Soon") })
}

// The production path cannot open Settings in a unit test (show() activates the app and scans the real cache),
// so these source guards pin the two links the tests above bypass; the behaviour is device-checked in #223.
@Test func issue220ProductionPathWiresUpdatePortIntoSettings() throws {
    let delegate = try String(contentsOf: repository.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
    #expect(delegate.components(separatedBy: "SettingsPanelWindow(").count == 2, "one construction site")
    let make = try #require(delegate.range(of: "func makeSettingsWindow("))
    let construction = try #require(delegate.range(of: "SettingsPanelWindow("))
    #expect(construction.lowerBound > make.lowerBound)
    let makeBody = delegate[make.lowerBound...].prefix { $0 != "}" }
    #expect(makeBody.contains("SettingsPanelWindow("))
    #expect(makeBody.contains("updates: updates"))
    let show = try #require(delegate.range(of: "func showSettings()"))
    #expect(delegate[show.lowerBound...].prefix { $0 != "}" }.contains("makeSettingsWindow("))

    let main = try String(contentsOf: repository.appendingPathComponent("App/MadoApp.swift"), encoding: .utf8)
    let assignment = try #require(main.range(of: #"\.updates\s*=\s*"#, options: .regularExpression))
    let run = try #require(main.range(of: ".run()"))
    #expect(assignment.lowerBound < run.lowerBound)
    let fixture = try #require(main.range(of: "#if DEBUG && PICSEE_UI_TEST_FIXTURE"))
    let otherwise = try #require(main.range(of: "#else", range: fixture.upperBound..<main.endIndex))
    let end = try #require(main.range(of: "#endif", range: otherwise.upperBound..<main.endIndex))
    #expect(!main[fixture.upperBound..<otherwise.lowerBound].contains("SparkleUpdatePort("))
    #expect(main[otherwise.upperBound..<end.lowerBound].contains("SparkleUpdatePort()"))
}
