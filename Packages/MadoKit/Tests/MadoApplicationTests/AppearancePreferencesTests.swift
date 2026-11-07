import Foundation
import Testing
import MadoApplication

@Test func appearancePreferencesDefaultIsSystem() {
    let value = DisplayPreferences()
    #expect(value.appearance == .system)
    #expect(value.alwaysShowTools == false)
    #expect(value.filmstripExpanded == false)
}

@Test func appearancePreferencesLiteralJSONAndFullDomainRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let cases: [(DisplayAppearance, Bool, Bool, String)] = [
        (.system, false, false, #"{"alwaysShowTools":false,"appearance":"system","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.system, false, true, #"{"alwaysShowTools":false,"appearance":"system","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.system, true, false, #"{"alwaysShowTools":true,"appearance":"system","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.system, true, true, #"{"alwaysShowTools":true,"appearance":"system","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.light, false, false, #"{"alwaysShowTools":false,"appearance":"light","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.light, false, true, #"{"alwaysShowTools":false,"appearance":"light","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.light, true, false, #"{"alwaysShowTools":true,"appearance":"light","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.light, true, true, #"{"alwaysShowTools":true,"appearance":"light","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.dark, false, false, #"{"alwaysShowTools":false,"appearance":"dark","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.dark, false, true, #"{"alwaysShowTools":false,"appearance":"dark","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.dark, true, false, #"{"alwaysShowTools":true,"appearance":"dark","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
        (.dark, true, true, #"{"alwaysShowTools":true,"appearance":"dark","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196}"#),
    ]
    for (appearance, tools, filmstrip, literal) in cases {
        let value = DisplayPreferences(alwaysShowTools: tools, filmstripExpanded: filmstrip, appearance: appearance)
        #expect(value.appearance == appearance)
        let data = try encoder.encode(value)
        #expect(String(decoding: data, as: UTF8.self) == literal)
        #expect(try JSONDecoder().decode(DisplayPreferences.self, from: data) == value)
        #expect(try JSONDecoder().decode(DisplayPreferences.self, from: Data(literal.utf8)) == value)
    }
}

@Test func appearancePreferencesLegacyUnknownAndExtraFields() {
    let legacy = #"{"alwaysShowTools":true,"filmstripExpanded":false}"#
    let unknown = #"{"alwaysShowTools":true,"appearance":"sepia","filmstripExpanded":false,"future":42}"#
    let extra = #"{"alwaysShowTools":false,"appearance":"light","filmstripExpanded":true,"search":"ignored"}"#
    let decoder = JSONDecoder()
    #expect((try? decoder.decode(DisplayPreferences.self, from: Data(legacy.utf8))) ==
        DisplayPreferences(alwaysShowTools: true, filmstripExpanded: false, appearance: .system))
    #expect((try? decoder.decode(DisplayPreferences.self, from: Data(unknown.utf8))) ==
        DisplayPreferences(alwaysShowTools: true, filmstripExpanded: false, appearance: .system))
    #expect((try? decoder.decode(DisplayPreferences.self, from: Data(extra.utf8))) ==
        DisplayPreferences(alwaysShowTools: false, filmstripExpanded: true, appearance: .light))
}
